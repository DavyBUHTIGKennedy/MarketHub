import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const hex = (bytes: Uint8Array) =>
  Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

async function sha256(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return hex(new Uint8Array(digest));
}

function marketStartUtc(eventDate: string, openingTime: string, timeZone = "Europe/London") {
  const dateMatch = /^(\d{4})-(\d{2})-(\d{2})$/.exec(eventDate);
  const timeMatch = /^(\d{2}):(\d{2})(?::(\d{2}))?/.exec(openingTime);
  if (!dateMatch || !timeMatch) throw new Error("The market date or opening time is invalid.");
  const [, y, mo, d] = dateMatch;
  const [, h, mi, sec = "0"] = timeMatch;
  const targetLocalAsUtc = Date.UTC(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(sec));
  let guess = targetLocalAsUtc;
  const formatter = new Intl.DateTimeFormat("en-GB", {
    timeZone, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
  });
  for (let i = 0; i < 4; i++) {
    const parts = Object.fromEntries(formatter.formatToParts(new Date(guess))
      .filter((part) => part.type !== "literal")
      .map((part) => [part.type, Number(part.value)]));
    const representedLocalAsUtc = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
    const next = guess + (targetLocalAsUtc - representedLocalAsUtc);
    if (next === guess) break;
    guess = next;
  }
  return new Date(guess);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) {
    return json({ error: "Invitation service is not configured." }, 500);
  }

  const adminDb = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid request body." }, 400);
  }

  if (body.action === "view") {
    const token = String(body.token || "");
    if (!/^[0-9a-f]{64}$/.test(token)) return json({ error: "This invitation link is invalid." }, 404);
    const tokenHash = await sha256(token);
    const { data: invite, error } = await adminDb
      .from("market_invitations")
      .select("id,status,event_name,event_date,location_name,opening_time,pitch_price,trader_name,expires_at,organizations(name)")
      .eq("token_hash", tokenHash)
      .maybeSingle();
    if (error) return json({ error: "Could not check this invitation." }, 500);
    if (!invite || !["pending", "viewed", "accepted"].includes(invite.status)) {
      return json({ error: "This invitation is no longer available. Please contact the market organiser." }, 404);
    }
    if (invite.status !== "accepted" && new Date(invite.expires_at).getTime() <= Date.now()) {
      await adminDb.from("market_invitations").update({ status: "expired" }).eq("id", invite.id);
      return json({ error: "This invitation has expired. Please contact the market organiser." }, 410);
    }
    if (invite.status === "pending") {
      await adminDb.from("market_invitations")
        .update({ status: "viewed", viewed_at: new Date().toISOString(), updated_at: new Date().toISOString() })
        .eq("id", invite.id).eq("status", "pending");
    }
    return json({
      invitation: {
        trader_name: invite.trader_name,
        invitation_status: invite.status,
        event_name: invite.event_name,
        event_date: invite.event_date,
        location_name: invite.location_name,
        opening_time: invite.opening_time,
        pitch_price: invite.pitch_price,
        organisation_name: (invite.organizations as { name?: string } | null)?.name || "Market organiser",
        expires_at: invite.expires_at,
      },
    });
  }

  if (body.action !== "issue") return json({ error: "Unknown invitation action." }, 400);

  const authHeader = req.headers.get("Authorization") || "";
  const jwt = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
  if (!jwt) return json({ error: "Sign in as a market owner to create invitations." }, 401);

  const authClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await authClient.auth.getUser();
  if (authError || !authData.user) return json({ error: "Your session is not valid. Please sign in again." }, 401);

  const eventId = String(body.event_id || "");
  const round = body.round === "priority" ? "priority" : "remaining";
  const baseUrl = String(body.base_url || "");
  let parsedBase: URL;
  try { parsedBase = new URL(baseUrl); } catch { return json({ error: "The invitation page address is invalid." }, 400); }
  const configuredBase = Deno.env.get("MARKET_APP_BASE_URL");
  const isLocalPreview = ["http://localhost:8000", "http://127.0.0.1:8000"].includes(parsedBase.origin);
  if (!isLocalPreview && (!configuredBase || parsedBase.origin !== new URL(configuredBase).origin)) {
    return json({ error: "This website address is not approved for invitation links. Configure MARKET_APP_BASE_URL first." }, 400);
  }

  const { data: event, error: eventError } = await adminDb
    .from("market_events")
    .select("id,organization_id,location_id,name,event_date,opening_time,pitch_price,status")
    .eq("id", eventId)
    .maybeSingle();
  if (eventError) return json({ error: "Market date lookup failed: " + eventError.message }, 500);
  if (!event) return json({ error: "Market date not found for the supplied event ID." }, 404);
  if (event.status !== "scheduled" || !event.opening_time) {
    return json({ error: "Invitations require a future scheduled market date with an opening time." }, 400);
  }
  let marketStart: Date;
  try {
    marketStart = marketStartUtc(event.event_date, String(event.opening_time));
  } catch {
    return json({ error: "The market opening date or time is invalid." }, 400);
  }
  const responseDeadline = new Date(marketStart.getTime() - 36 * 60 * 60 * 1000);
  const expiresAt = responseDeadline.toISOString();
  if (responseDeadline.getTime() <= Date.now()) {
    return json({ error: "The invitation response deadline has passed (36 hours before market opening)." }, 400);
  }

  const { data: membership, error: memberError } = await adminDb
    .from("organization_memberships")
    .select("role")
    .eq("organization_id", event.organization_id)
    .eq("user_id", authData.user.id)
    .maybeSingle();
  if (memberError || !membership || !["owner", "admin"].includes(membership.role)) {
    return json({ error: "You do not have permission to invite traders for this organisation." }, 403);
  }

  const [{ data: location }, { data: org }, { data: preferences }, { data: existing }] = await Promise.all([
    adminDb.from("market_locations").select("name").eq("id", event.location_id).single(),
    adminDb.from("organizations").select("name").eq("id", event.organization_id).single(),
    adminDb.from("market_trader_location_preferences").select("trader_id")
      .eq("organization_id", event.organization_id).eq("location_id", event.location_id).eq("is_eligible", true),
    adminDb.from("market_invitations").select("trader_id,status,expires_at")
      .eq("organization_id", event.organization_id).eq("event_id", event.id),
  ]);
  if (!location || !preferences) return json({ error: "Could not load eligible traders for this market date." }, 500);

  const eligibleIds = preferences.map((p: { trader_id: string }) => p.trader_id);
  const existingByTrader = new Map((existing || []).map((i: { trader_id: string; status: string; expires_at: string }) => [i.trader_id, i]));
  const { data: traders, error: traderError } = eligibleIds.length
    ? await adminDb.from("market_traders")
      .select("id,email,full_name,is_priority")
      .eq("organization_id", event.organization_id).eq("active", true).in("id", eligibleIds)
      .order("is_priority", { ascending: false }).order("full_name")
    : { data: [], error: null };
  if (traderError) return json({ error: "Could not load the trader directory." }, 500);

  const roundTraders = (traders || []).filter((t: { is_priority: boolean }) =>
    round === "priority" ? t.is_priority : !t.is_priority
  );
  const candidates = roundTraders.filter((t: { id: string }) => {
    const old = existingByTrader.get(t.id) as { status: string; expires_at: string } | undefined;
    const stillActiveWithSameDeadline = old
      && ["pending", "viewed"].includes(old.status)
      && old.expires_at === expiresAt;
    if (stillActiveWithSameDeadline || old?.status === "accepted") return false;
    return true;
  });
  const issued: Array<{ name: string; email: string; url: string }> = [];
  for (const trader of candidates) {
    const tokenBytes = crypto.getRandomValues(new Uint8Array(32));
    const token = hex(tokenBytes);
    const tokenHash = await sha256(token);
    const record = {
      organization_id: event.organization_id,
      event_id: event.id,
      trader_id: trader.id,
      token_hash: tokenHash,
      status: "pending",
      event_name: event.name,
      event_date: event.event_date,
      location_name: location.name,
      opening_time: event.opening_time,
      pitch_price: event.pitch_price,
      trader_name: trader.full_name || trader.email,
      issued_at: new Date().toISOString(),
      expires_at: expiresAt,
      created_by: authData.user.id,
      updated_at: new Date().toISOString(),
    };
    const { error: saveError } = await adminDb.from("market_invitations").upsert(record, { onConflict: "event_id,trader_id" });
    if (saveError) return json({ error: "Could not save an invitation. No links have been returned. " + saveError.message }, 500);
    const link = new URL("invite.html", parsedBase.toString().endsWith("/") ? parsedBase : parsedBase.toString() + "/");
    link.searchParams.set("token", token);
    issued.push({ name: trader.full_name || trader.email, email: trader.email, url: link.toString() });
  }

  return json({
    event_name: event.name,
    location_name: location.name,
    round,
    created: issued.length,
    skipped: roundTraders.length - candidates.length,
    invitations: issued,
    message: issued.length
      ? "Invitation links created. They have not been emailed; copy and send each link to its named trader."
      : "No new eligible traders were available for this invitation round.",
  });
});
