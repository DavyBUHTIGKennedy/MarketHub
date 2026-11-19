(() => {
  const root = document.getElementById("marketApp");
  const esc = value => String(value ?? "").replace(/[&<>"']/g, ch => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[ch]));
  const dateText = value => value ? new Date(value + "T12:00:00").toLocaleDateString("en-GB",{day:"numeric",month:"short",year:"numeric"}) : "";
  const todayISO = () => {
    const d = new Date();
    return d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0");
  };
  window.startMarketHubApp = (client, session, memberships) => {
    let membership = memberships[0];
    let locations = [], pitches = [], events = [], tab = "overview";
    let month = new Date(); month.setDate(1);
    let selectedDate = "";
    const isAdmin = () => ["owner","admin"].includes(membership.role);
    const orgId = () => membership.organization_id;
    const message = (text, bad=false) => {
      const el = root.querySelector("#mhMessage");
      if (el) { el.textContent=text; el.style.color=bad?"#a83d36":"#155b4d"; }
    };
    const shell = () => {
      const orgOptions = memberships.length > 1
        ? '<label class="mh-muted" for="mhOrg">Organisation</label><select id="mhOrg">'+memberships.map((m,i)=>'<option value="'+i+'" '+(m===membership?'selected':'')+'>'+esc(m.organizations?.name||"Market organisation")+' — '+esc(m.role)+'</option>').join("")+'</select>'
        : '<small>'+esc(membership.organizations?.name||"Market organisation")+' · '+esc(membership.role)+'</small>';
      root.innerHTML = '<div class="mh-top"><div><div style="font-size:21px;font-weight:800">MarketHub</div><small>'+esc(session.user.email)+' · '+esc(membership.role)+'</small></div><div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">'+orgOptions+'<button class="mh-button secondary" id="mhSignOut">Sign out</button></div></div><nav class="mh-nav"><button data-tab="overview">Overview</button><button data-tab="calendar">Market calendar</button><button data-tab="pitches">Locations & pitches</button></nav><div id="mhMessage" class="mh-muted" role="status"></div><div id="mhContent"></div>';
      root.querySelector("#mhSignOut").onclick=async()=>{const {error}=await client.auth.signOut();if(error)message("Sign out failed: "+error.message,true);};
      root.querySelectorAll("[data-tab]").forEach(b=>b.onclick=()=>{tab=b.dataset.tab;render();});
      const orgSelect=root.querySelector("#mhOrg");
      if(orgSelect)orgSelect.onchange=()=>{membership=memberships[Number(orgSelect.value)];locations=[];pitches=[];events=[];shell();loadData();};
    };
    const loadData = async () => {
      message("Loading your market data…");
      const [l,p,e] = await Promise.all([
        client.from("market_locations").select("id,name,address,active,default_pitch_capacity").eq("organization_id",orgId()).order("name"),
        client.from("pitches").select("id,location_id,pitch_code,description,weekly_price,active").eq("organization_id",orgId()).order("pitch_code"),
        client.from("market_events").select("id,location_id,name,event_date,opening_time,status,cancellation_message,pitch_capacity").eq("organization_id",orgId()).order("event_date")
      ]);
      const errors=[l.error,p.error,e.error].filter(Boolean);
      if(errors.length){message("Could not load market data: "+errors.map(x=>x.message).join(" · "),true);return;}
      locations=l.data||[];pitches=p.data||[];events=e.data||[];
      message("Live data loaded from Supabase. Changes are saved to the organisation database.");
      render();
    };
    const locationName = id => locations.find(x=>x.id===id)?.name||"Location";
    const overview = () => {
      const total=locations.filter(x=>x.active).reduce((n,x)=>n+Number(x.default_pitch_capacity||0),0);
      return '<div class="mh-grid"><div class="mh-card"><strong style="font-size:27px">'+locations.filter(x=>x.active).length+'</strong><div class="mh-muted">Active locations</div></div><div class="mh-card"><strong style="font-size:27px">'+total+'</strong><div class="mh-muted">Normal pitch capacity</div></div><div class="mh-card"><strong style="font-size:27px">'+events.filter(x=>x.status==="scheduled").length+'</strong><div class="mh-muted">Scheduled market dates</div></div></div><div class="mh-card"><h2>Market setup</h2><p>Each location has one normal pitch capacity. New market dates inherit that number automatically; an owner can change the capacity for an individual date when needed.</p><p class="mh-muted">Individual pitch and booking records are retained behind the scenes for future allocation and reporting.</p></div>';
    };
    const calendar = () => {
      const y=month.getFullYear(),m=month.getMonth(),first=new Date(y,m,1),days=new Date(y,m+1,0).getDate(),offset=(first.getDay()+6)%7;
      let out='<div class="mh-card"><div style="display:flex;justify-content:space-between;align-items:center"><button class="mh-button secondary" id="mhPrev">‹</button><h2>'+month.toLocaleDateString("en-GB",{month:"long",year:"numeric"})+'</h2><button class="mh-button secondary" id="mhNext">›</button></div><div class="mh-grid" style="grid-template-columns:repeat(7,minmax(0,1fr));gap:5px">'+["Mon","Tue","Wed","Thu","Fri","Sat","Sun"].map(d=>'<div class="mh-muted" style="text-align:center">'+d+'</div>').join("");
      for(let i=0;i<offset;i++)out+='<div></div>';
      for(let d=1;d<=days;d++){
        const date=y+"-"+String(m+1).padStart(2,"0")+"-"+String(d).padStart(2,"0");
        const count=events.filter(e=>e.event_date===date&&e.status==="scheduled").length;
        out+='<button data-date="'+date+'" class="mh-button '+(selectedDate===date?'':'secondary')+'" style="min-height:58px;padding:5px;opacity:'+(count?1:.72)+'"><b>'+d+'</b>'+(count?'<small style="display:block">'+count+' market'+(count>1?'s':'')+'</small>':'')+'</button>';
      }
      out+='</div><p class="mh-muted">Choose a date to see scheduled markets.</p></div>';
      const shown=selectedDate?events.filter(e=>e.event_date===selectedDate):events.filter(e=>e.status==="scheduled");
      out+='<div class="mh-card"><h2>'+(selectedDate?"Markets on "+dateText(selectedDate):"Scheduled markets")+'</h2>';
      out+=shown.length?shown.map(e=>'<div class="mh-row"><div><b>'+esc(e.name)+'</b><div class="mh-muted">'+esc(locationName(e.location_id))+' · '+dateText(e.event_date)+(e.opening_time?' · '+esc(String(e.opening_time).slice(0,5)):'')+'</div></div><div style="text-align:right"><b>'+Number(e.pitch_capacity||0)+' pitches</b><div>'+(e.status==="cancelled"?'Cancelled': 'Scheduled')+(isAdmin()&&e.status==="scheduled"?' <button class="mh-button secondary" data-cancel="'+e.id+'">Cancel</button>':'')+'</div></div></div>').join(""):'<p class="mh-muted">No market dates to show.</p>';
      if(isAdmin())out+='<h3 style="margin-top:18px">Create a market date</h3><form id="mhEventForm" class="mh-grid"><div class="mh-field"><label>Market name</label><input name="name" required placeholder="e.g. Newcastle Market"></div><div class="mh-field"><label>Location</label><select name="location_id" id="mhEventLocation" required>'+locations.filter(x=>x.active).map(x=>'<option value="'+x.id+'" data-capacity="'+Number(x.default_pitch_capacity||0)+'">'+esc(x.name)+'</option>').join("")+'</select></div><div class="mh-field"><label>Date</label><input name="event_date" type="date" min="'+todayISO()+'" required></div><div class="mh-field"><label>Opening time</label><input name="opening_time" type="time" value="09:00"></div><div class="mh-field"><label>Pitch capacity for this date</label><input id="mhEventCapacity" name="pitch_capacity" type="number" min="0" step="1" value="'+Number(locations.find(x=>x.active)?.default_pitch_capacity||0)+'" required><small class="mh-muted">Starts with the location's normal capacity. Change only if this date is different.</small></div><div><button class="mh-button" '+(!locations.length?'disabled':'')+'>Create market date</button></div></form><p class="mh-muted">Cancelling a date changes its status in the database. Trader notifications are not connected yet.</p>';
      out+='</div>';return out;
    };
    const pitchPage = () => {
      let out='<div class="mh-card"><h2>Locations & pitch capacity</h2><p class="mh-muted">Set one normal pitch number for each location. This is copied to every new market date and can be adjusted for an individual date in the calendar.</p>';
      out+=locations.length?locations.map(loc=>'<section style="margin:14px 0;padding:14px;border:1px solid #dce5df;border-radius:12px"><div style="display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap"><div><h3 style="margin:0">'+esc(loc.name)+'</h3>'+(loc.address?'<p class="mh-muted">'+esc(loc.address)+'</p>':'')+'</div><div style="text-align:center;min-width:110px;padding:10px 16px;background:#e7f2ed;border-radius:10px"><strong style="font-size:26px">'+Number(loc.default_pitch_capacity||0)+'</strong><div class="mh-muted">pitches</div></div></div>'+(isAdmin()?'<form data-capacity-form="'+loc.id+'" style="display:flex;gap:8px;align-items:end;flex-wrap:wrap;margin-top:12px"><div class="mh-field" style="margin:0;min-width:150px"><label>Normal pitch capacity</label><input name="capacity" type="number" min="0" step="1" value="'+Number(loc.default_pitch_capacity||0)+'" required></div><button class="mh-button secondary">Save capacity</button></form>':'')+'</section>').join(""):'<p class="mh-muted">No locations have been created for this organisation yet.</p>';
      if(isAdmin()) {
        out+='<hr style="border:0;border-top:1px solid #dce5df;margin:20px 0"><h3>Add a location</h3><form id="mhLocationForm" class="mh-grid"><div class="mh-field"><label>Location name</label><input name="name" required placeholder="e.g. Warrenpoint"></div><div class="mh-field"><label>Address (optional)</label><input name="address"></div><div class="mh-field"><label>Normal pitch capacity</label><input name="capacity" type="number" min="0" step="1" value="7" required></div><div><button class="mh-button">Add location</button></div></form>';
      }
      out+='</div>';return out;
    };
    const render = () => {
      root.querySelectorAll("[data-tab]").forEach(b=>b.classList.toggle("active",b.dataset.tab===tab));
      const content=root.querySelector("#mhContent");
      content.innerHTML=tab==="calendar"?calendar():tab==="pitches"?pitchPage():overview();
      root.querySelector("#mhPrev")?.addEventListener("click",()=>{month.setMonth(month.getMonth()-1);render();});
      root.querySelector("#mhNext")?.addEventListener("click",()=>{month.setMonth(month.getMonth()+1);render();});
      content.querySelectorAll("[data-date]").forEach(b=>b.onclick=()=>{selectedDate=b.dataset.date;render();});
      content.querySelector("#mhEventLocation")?.addEventListener("change",ev=>{
        const option=ev.target.selectedOptions[0];
        const field=content.querySelector("#mhEventCapacity");
        if(field)field.value=option?.dataset.capacity||0;
      });
      content.querySelectorAll("[data-cancel]").forEach(b=>b.onclick=async()=>{
        if(!confirm("Cancel this market date? This does not send trader notifications."))return;
        const {error}=await client.from("market_events").update({status:"cancelled"}).eq("id",b.dataset.cancel).eq("organization_id",orgId());
        if(error){message("Could not cancel market date: "+error.message,true);return;}
        await loadData();
      });
      content.querySelectorAll("[data-capacity-form]").forEach(form=>form.addEventListener("submit",async ev=>{
        ev.preventDefault();
        const capacity=Number(new FormData(form).get("capacity"));
        if(!Number.isInteger(capacity)||capacity<0){message("Enter a whole number of zero or more pitches.",true);return;}
        const {error}=await client.from("market_locations").update({default_pitch_capacity:capacity}).eq("id",form.dataset.capacityForm).eq("organization_id",orgId());
        if(error){message("Could not save pitch capacity: "+error.message,true);return;}
        await loadData();tab="pitches";render();
      }));
      content.querySelector("#mhLocationForm")?.addEventListener("submit",async ev=>{
        ev.preventDefault();const fd=new FormData(ev.target);
        const {error}=await client.from("market_locations").insert({organization_id:orgId(),name:String(fd.get("name")).trim(),address:String(fd.get("address")||"").trim()||null,default_pitch_capacity:Number(fd.get("capacity")),active:true});
        if(error){message("Could not add location: "+error.message,true);return;}
        await loadData();tab="pitches";render();
      });
      content.querySelector("#mhEventForm")?.addEventListener("submit",async ev=>{
        ev.preventDefault();const fd=new FormData(ev.target);
        const {error}=await client.from("market_events").insert({organization_id:orgId(),location_id:fd.get("location_id"),name:String(fd.get("name")).trim(),event_date:fd.get("event_date"),opening_time:fd.get("opening_time")||null,pitch_capacity:Number(fd.get("pitch_capacity")),status:"scheduled"});
        if(error){message("Could not create market date: "+error.message,true);return;}
        selectedDate=fd.get("event_date");await loadData();tab="calendar";render();
      });
    };
    shell();loadData();
  };
})();
