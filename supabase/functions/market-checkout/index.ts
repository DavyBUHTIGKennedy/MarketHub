import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, stripe-signature",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
const hex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
const encoder = new TextEncoder();

async function sha256(value: string) {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}
async function verifyStripeSignature(rawBody: string, header: string, secret: string) {
  const parts = header.split(",").map((part) => part.trim());
  const timestamp = parts.find((part) => part.startsWith("t="))?.slice(2);
  const signatures = parts.filter((part) => part.startsWith("v1=")).map((part) => part.slice(3));
  if (!timestamp || !/^\d+$/.test(timestamp) || !signatures.length) return false;
  if (Math.abs(Date.now() / 1000 - Number(timestamp)) > 300) return false;
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const expected = hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(timestamp + "." + rawBody))));
  return signatures.some((candidate) => {
    if (candidate.length !== expected.length) return false;
    let diff = 0;
    for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ candidate.charCodeAt(i);
    return diff === 0;
  });
}

async function stripeRequest(path: string, secret: string, params: URLSearchParams, idempotencyKey: string) {
  return await fetch("https://api.stripe.com/v1/" + path, {
    method: "POST",
    headers: {
      Authorization: "Bearer " + secret,
      "Content-Type": "application/x-www-form-urlencoded",
      "Idempotency-Key": idempotencyKey,
    },
    body: params.toString(),
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return json({ error: "Payment service is not configured." }, 500);
  const db = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

  // Stripe sends signed raw JSON to this same endpoint. No browser auth is used
  // for webhooks; authenticity is established by the Stripe signature.
  if (req.headers.has("Stripe-Signature")) {
    const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
    const stripeSecret = Deno.env.get("STRIPE_SECRET_KEY");
    if (!webhookSecret || !stripeSecret) return json({ error: "Stripe webhook is not configured." }, 500);
    const rawBody = await req.text();
    const signature = req.headers.get("Stripe-Signature") || "";
    if (!await verifyStripeSignature(rawBody, signature, webhookSecret)) {
      return json({ error: "Invalid Stripe webhook signature." }, 400);
    }

    let event: Record<string, any>;
    try { event = JSON.parse(rawBody); } catch { return json({ error: "Invalid Stripe event body." }, 400); }
    const session = event?.data?.object;
    const sessionId = typeof session?.id === "string" ? session.id : "";
    const paymentIntent = typeof session?.payment_intent === "string"
      ? session.payment_intent
      : session?.payment_intent?.id || null;

    if (!sessionId) return json({ received: true, ignored: true });

    const { data: processed, error } = await db.rpc("process_market_stripe_event", {
      p_stripe_event_id: String(event.id || ""),
      p_event_type: String(event.type || ""),
      p_checkout_session_id: sessionId,
      p_payment_intent_id: paymentIntent,
      p_amount_total: Number.isInteger(session.amount_total) ? session.amount_total : 0,
      p_currency: String(session.currency || ""),
      p_payment_status: String(session.payment_status || ""),
    });
    if (error) return json({ error: "Could not process payment event: " + error.message }, 500);

    // If payment arrived after the hold expired or failed validation, automatically
    // refund it. The refund is idempotent; duplicate webhook deliveries retry a
    // previously failed refund rather than creating another refund.
    let refundRequired = processed?.result === "refund_required";
    if (processed?.result === "duplicate") {
      const { data: prior } = await db.from("market_payment_transactions")
        .select("status,stripe_payment_intent_id")
        .eq("stripe_checkout_session_id", sessionId).maybeSingle();
      refundRequired = prior?.status === "refund_required";
      if (refundRequired) paymentIntent && (processed.payment_intent_id = paymentIntent);
      if (refundRequired && prior?.stripe_payment_intent_id) processed.payment_intent_id = prior.stripe_payment_intent_id;
    }
    if (refundRequired) {
      const refundIntent = processed?.payment_intent_id || paymentIntent;
      if (!refundIntent) return json({ error: "Refund required but Stripe payment intent is missing." }, 500);
      const refundParams = new URLSearchParams({ payment_intent: refundIntent, reason: "duplicate" });
      const refundResponse = await stripeRequest("refunds", stripeSecret, refundParams, "markethub-refund-" + sessionId);
      if (!refundResponse.ok) {
        const detail = await refundResponse.text();
        return json({ error: "Automatic refund needs retry: " + detail }, 500);
      }
      await db.from("market_payment_transactions").update({ status: "refunded", updated_at: new Date().toISOString() })
        .eq("stripe_checkout_session_id", sessionId);
      await db.from("market_reservations").update({ status: "refunded", updated_at: new Date().toISOString() })
        .eq("stripe_checkout_session_id", sessionId);
    }
    return json({ received: true, result: processed?.result || "ignored" });
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "Invalid request body." }, 400); }
  if (body.action !== "checkout") return json({ error: "Unknown payment action." }, 400);

  const stripeSecret = Deno.env.get("STRIPE_SECRET_KEY");
  if (!stripeSecret) return json({ error: "Card payments are not configured yet. Please contact the market organiser." }, 503);

  const token = String(body.token || "");
  if (!/^[0-9a-f]{64}$/.test(token)) return json({ error: "This invitation link is invalid." }, 404);
  const tokenHash = await sha256(token);
  const baseUrl = String(body.base_url || "");
  let parsedBase: URL;
  try { parsedBase = new URL(baseUrl); } catch { return json({ error: "The return address is invalid." }, 400); }
  const configuredBase = Deno.env.get("MARKET_APP_BASE_URL");
  const isLocalPreview = ["http://localhost:8000", "http://127.0.0.1:8000"].includes(parsedBase.origin);
  if (!isLocalPreview && (!configuredBase || parsedBase.origin !== new URL(configuredBase).origin)) {
    return json({ error: "This website address is not approved for checkout." }, 400);
  }

  const { data: reservation, error: reserveError } = await db.rpc("create_market_reservation", { p_token_hash: tokenHash });
  if (reserveError || !reservation) {
    return json({ error: reserveError?.message || "Could not reserve a pitch." }, 409);
  }
  if (reservation.checkout_url) {
    return json({ checkout_url: reservation.checkout_url, reservation_id: reservation.reservation_id, reused: true });
  }

  const amountMinor = Math.round(Number(reservation.amount) * 100);
  if (!Number.isSafeInteger(amountMinor) || amountMinor < 0) {
    await db.from("market_reservations").update({ status: "cancelled", updated_at: new Date().toISOString() })
      .eq("id", reservation.reservation_id).eq("status", "held");
    return json({ error: "The market pitch price is invalid." }, 500);
  }

  const expiresAt = Math.floor(Date.now() / 1000) + 30 * 60;
  const successUrl = parsedBase.origin + parsedBase.pathname.replace(/\/?$/, "/")
    + "invite.html?token=" + encodeURIComponent(token) + "&payment=success&session_id={CHECKOUT_SESSION_ID}";
  const cancelUrl = parsedBase.origin + parsedBase.pathname.replace(/\/?$/, "/")
    + "invite.html?token=" + encodeURIComponent(token) + "&payment=cancelled";

  const params = new URLSearchParams();
  params.set("mode", "payment");
  params.set("success_url", successUrl);
  params.set("cancel_url", cancelUrl);
  params.set("client_reference_id", reservation.reservation_id);
  params.set("expires_at", String(expiresAt));
  params.set("line_items[0][quantity]", "1");
  params.set("line_items[0][price_data][currency]", "gbp");
  params.set("line_items[0][price_data][unit_amount]", String(amountMinor));
  params.set("line_items[0][price_data][product_data][name]", "Market pitch");
  params.set("line_items[0][price_data][product_data][description]", "MarketHub trader pitch reservation");
  params.set("payment_intent_data[metadata][reservation_id]", reservation.reservation_id);
  params.set("metadata[reservation_id]", reservation.reservation_id);
  params.set("metadata[invitation_token_hash]", tokenHash);

  const idempotencyKey = "markethub-checkout-" + reservation.reservation_id + "-" + String(reservation.hold_expires_at);
  const stripeResponse = await stripeRequest("checkout/sessions", stripeSecret, params, idempotencyKey);
  const stripeResult = await stripeResponse.json().catch(() => ({}));
  if (!stripeResponse.ok || !stripeResult.id || !stripeResult.url) {
    await db.from("market_reservations").update({ status: "cancelled", updated_at: new Date().toISOString() })
      .eq("id", reservation.reservation_id).eq("status", "held");
    return json({ error: stripeResult?.error?.message || "Stripe could not start checkout." }, 502);
  }

  const { error: saveError } = await db.from("market_payment_transactions").insert({
    organization_id: reservation.organization_id,
    reservation_id: reservation.reservation_id,
    stripe_checkout_session_id: stripeResult.id,
    checkout_url: stripeResult.url,
    amount_minor: amountMinor,
    currency: "GBP",
    status: "checkout_open",
  });
  if (saveError) {
    const expireParams = new URLSearchParams();
    await stripeRequest("checkout/sessions/" + stripeResult.id + "/expire", stripeSecret, expireParams, "markethub-expire-" + stripeResult.id);
    await db.from("market_reservations").update({ status: "cancelled", updated_at: new Date().toISOString() })
      .eq("id", reservation.reservation_id).eq("status", "held");
    return json({ error: "Checkout could not be safely recorded. No booking has been made; please try again." }, 500);
  }

  const { error: attachError } = await db.from("market_reservations").update({
    stripe_checkout_session_id: stripeResult.id,
    stripe_checkout_url: stripeResult.url,
    updated_at: new Date().toISOString(),
  }).eq("id", reservation.reservation_id).eq("status", "held");
  if (attachError) return json({ error: "Checkout was created but could not be linked to the reservation. Please contact the market organiser." }, 500);

  return json({ checkout_url: stripeResult.url, reservation_id: reservation.reservation_id, reused: false });
});
