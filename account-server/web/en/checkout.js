"use strict";
const el=id=>document.getElementById(id);
let session=JSON.parse(sessionStorage.getItem("smooth-session")||"null"),challenge,catalog,busy=false;
const money=amount=>new Intl.NumberFormat("en-US",{style:"currency",currency:"USD"}).format(amount/100);
const title=p=>p.id==="smooth_yearly"?"One year of access":"Lifetime access";
const tell=text=>el("message").textContent=text;
async function api(path,body){
  const r=await fetch("/v1/"+path,{method:body?"POST":"GET",headers:{"Content-Type":"application/json",...(session?{Authorization:"Bearer "+session.token}:{})},...(body?{body:JSON.stringify(body)}:{})});
  const value=await r.json();if(!r.ok){if(r.status===401&&!path.startsWith("auth/"))signOut();const fallback=r.status===429?"Too many attempts. Wait a minute and try again.":r.status===401?"Check your sign-in code or sign in again.":"The request could not be completed. Please try again.";throw new Error(value.message&&!/[가-힣]/.test(value.message)?value.message:fallback);}return value;
}
async function action(fn){if(busy)return;busy=true;document.querySelectorAll("button").forEach(b=>b.disabled=true);try{await fn();}catch(error){tell(error.message);}finally{busy=false;document.querySelectorAll("button").forEach(b=>b.disabled=false);}}
function signOut(){session=null;sessionStorage.removeItem("smooth-session");el("login").hidden=false;el("account").hidden=true;}
el("email-form").onsubmit=e=>{e.preventDefault();action(async()=>{challenge=(await api("auth/code",{email:el("email").value})).challengeId;el("code-form").hidden=false;el("code").focus();tell("Enter the 8-digit code sent to your email.");});};
el("code-form").onsubmit=e=>{e.preventDefault();action(async()=>{session=await api("auth/verify",{challengeId:challenge,code:el("code").value});sessionStorage.setItem("smooth-session",JSON.stringify(session));el("code").value="";await show();tell("Signed in. Choose your license below.");await finish();});};
el("logout").onclick=()=>action(async()=>{try{await api("auth/logout",{});}finally{signOut();tell("Signed out.");}});
el("refresh").onclick=()=>action(async()=>{await show();tell("License checked. Refresh your license in the Mac app too.");});
async function show(){
  const me=await api("me"),license=JSON.parse(atob(me.license.payload)),active=license.products.length>0;
  el("login").hidden=true;el("account").hidden=false;el("identity").textContent=me.email;
  el("license").classList.toggle("active",active);el("license-title").textContent=active?"Your license is active":"Ready to upgrade";
  el("license-detail").textContent=active?"Open Account in Smooth Player and refresh your license.":"Approve a payment to activate your license.";
  el("products").replaceChildren();
  if(!active)for(const p of catalog.paypal?.products||[]){
    const card=document.createElement("div");card.className="product";
    const heading=document.createElement("h3"),price=document.createElement("span");price.className="price";price.textContent=money(p.amount);heading.append(document.createTextNode(title(p)),price);
    const detail=document.createElement("p");detail.textContent=p.id==="smooth_yearly"?"12 months from payment. One payment, no automatic renewal.":"One payment. No automatic renewal.";
    const label=document.createElement("label");label.className="consent";const consent=document.createElement("input");consent.type="checkbox";label.append(consent,document.createTextNode("I have tried the app and agree to the terms and refund policy linked below."));
    const button=document.createElement("button");button.className="paypal";button.textContent=catalog.environment==="test"?"Pay with PayPal · Sandbox":"Pay with PayPal";
    button.onclick=()=>action(async()=>{if(!consent.checked){tell("Please review and accept the terms and refund policy before paying.");consent.focus();return;}await buy(p);});card.append(heading,detail,label,button);el("products").append(card);
  }
  if(!active&&!catalog.paypal?.products.length)el("products").textContent="PayPal checkout is being prepared. Please check back soon.";
  const {orders}=await api("paypal/orders");el("history").hidden=!orders.length;el("orders").replaceChildren();
  for(const order of orders){const row=document.createElement("div");row.className="order";const text=document.createElement("p");text.textContent=title({id:order.product})+" · "+money(order.amount)+" · "+({done:"Payment complete",cancelled:"Cancelled / refunded",pending:"Payment pending",created:"Awaiting approval"}[order.status]||order.status);row.append(text);
    if(["created","pending"].includes(order.status)){const b=document.createElement("button");b.className="secondary";b.textContent="Check payment";b.onclick=()=>action(()=>complete(order.id));row.append(b);}
    if(catalog.environment==="test"&&order.status==="done"){const b=document.createElement("button");b.className="secondary";b.textContent="Refund sandbox payment";b.onclick=()=>action(async()=>{if(confirm("Refund this sandbox payment and remove its license?")){const result=await api("paypal/orders/"+encodeURIComponent(order.id)+"/refund",{});await show();tell(result.status==="cancelled"?"Sandbox payment refunded. Its license is no longer active.":"Refund requested. Check the payment again shortly.");}});row.append(b);}el("orders").append(row);}
}
async function buy(product){
  const order=await api("paypal/orders",{product:product.id,amount:product.amount,termsVersion:catalog.termsVersion,language:"en"});
  if(order.completed){await show();tell("Payment complete. Your license is ready.");return;}
  if(order.approved){await complete(order.orderId);return;}
  const url=new URL(order.approvalURL),host=catalog.paypal.environment==="sandbox"?"www.sandbox.paypal.com":"www.paypal.com";
  if(url.protocol!=="https:"||url.hostname!==host||url.username||url.password||(url.port&&url.port!=="443"))throw new Error("The PayPal payment address could not be verified.");
  location.assign(url.href);
}
async function complete(id){const result=await api("paypal/orders/"+encodeURIComponent(id)+"/capture",{});await show();tell(result.status==="done"?"Payment complete. Your license is ready in Smooth Player.":result.status==="cancelled"?"This payment was cancelled or refunded.":"PayPal is still processing this payment. Use Check payment to try again shortly.");}
async function finish(){const q=new URLSearchParams(location.search);if(q.get("flow")==="paypal-cancel"){history.replaceState(null,"",location.pathname);tell("Payment cancelled. No license was issued.");return;}if(q.get("flow")!=="paypal")return;if(!session){tell("Sign in with the account you used to start this payment.");return;}if(!q.get("order"))throw new Error("Payment reference missing.");await complete(q.get("order"));history.replaceState(null,"",location.pathname);}
action(async()=>{
  catalog=await api("catalog");el("environment").hidden=catalog.environment!=="test";el("environment").textContent="SANDBOX DEMO · No real money is charged. This license works only in the separate demo app.";
  for(const p of catalog.paypal?.products||[]){const row=document.createElement("p");row.textContent=title(p)+" · US"+money(p.amount)+" · No automatic renewal";el("offers").append(row);}
  for(const [path,label] of [["privacy","Privacy"],["terms","Terms & refunds"],["support","Support"]]){const a=document.createElement("a");a.href="/"+path+"?lang=en";a.textContent=label;el("links").append(a);}
  el("seller").textContent=Object.values(catalog.seller||{}).filter(Boolean).join(" · ");
  if(session)await show();await finish();
});
