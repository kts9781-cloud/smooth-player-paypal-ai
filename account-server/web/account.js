"use strict";
const el = id => document.getElementById(id);
let session = JSON.parse(sessionStorage.getItem("smooth-session") || "null");
let challenge, catalog;
let providers = [], working = false;
const intervalLabel = p => p.period === "P1Y" || p.id === "smooth_yearly" ? "년" : "월";
const renewalLabel = p => p.period === "P1Y" || p.id === "smooth_yearly" ? "매년" : "매월";
const message = text => { el("message").textContent = text; };
async function api(path, body, method) {
  const response = await fetch("/v1/" + path, { method: method || (body ? "POST" : "GET"), headers: {"Content-Type":"application/json", ...(session ? {Authorization:"Bearer " + session.token} : {})}, ...(body ? {body:JSON.stringify(body)} : {}) });
  const value = await response.json();
  if (!response.ok) { if(response.status === 401 && path !== "auth/verify" && path !== "auth/social/complete") clearSession(); throw new Error(value.message || "요청을 완료하지 못했습니다."); }
  return value;
}
function clearSession(){ session=null; sessionStorage.removeItem("smooth-session"); sessionStorage.removeItem("smooth-social"); el("login").hidden=false; el("account").hidden=true; el("complimentary").hidden=true; el("complimentary-code").value=""; }
async function action(callback){ if(working)return; working=true; document.querySelectorAll("button").forEach(b=>b.disabled=true); try{await callback();}catch(e){message(e.message);}finally{working=false; document.querySelectorAll("button").forEach(b=>b.disabled=b.dataset.unavailable === "true");} }
el("email-form").onsubmit = event => {event.preventDefault(); action(async()=>{ challenge=(await api("auth/code",{email:el("email").value})).challengeId; el("code-form").hidden=false; message("이메일로 인증 코드를 보냈습니다."); });};
el("code-form").onsubmit = event => {event.preventDefault(); action(async()=>{ session=await api("auth/verify",{challengeId:challenge,code:el("code").value}); sessionStorage.setItem("smooth-session",JSON.stringify(session)); el("code").value=""; await showAccount(); message("로그인했습니다."); await finishPayment(); });};
el("logout").onclick=()=>action(async()=>{try{await api("auth/logout",{});}finally{clearSession();await loadProviders();message("로그아웃했습니다.");}});
el("refresh").onclick=()=>action(async()=>{await showAccount();message("이용권을 확인했습니다. 앱에서도 ‘다시 확인’을 눌러 주세요.");});
el("complimentary-form").onsubmit=event=>{event.preventDefault();action(async()=>{await api("complimentary/redeem",{code:el("complimentary-code").value});el("complimentary-code").value="";await showAccount();message("무료 평생 이용권이 계정에 등록되었습니다. 앱에서 ‘이용권 다시 확인’을 눌러 주세요.");});};
el("delete").onclick=()=>action(async()=>{if(confirm("회원 계정을 삭제할까요? 토스 자동결제는 중단됩니다. Apple·Google 구독은 해당 스토어에서 별도로 해지해야 합니다. 구매 연결 기록은 정산과 중복 연결 방지를 위해 보관됩니다.")){await api("account",null,"DELETE");clearSession();await loadProviders();message("계정을 삭제했습니다.");}});
async function showAccount(){
  const me=await api("me"); el("login").hidden=true; el("account").hidden=false; el("identity").textContent=me.email;
  const payload=JSON.parse(atob(me.license.payload)); // Display only; native apps verify the signature before unlocking.
  el("entitlement").textContent=me.sources.includes("complimentary") ? "무료 평생 이용권 사용 중" : payload.products.length ? "이용권 사용 중 · " + me.sources.join(" / ") : "연결된 이용권이 없습니다.";
  el("complimentary").hidden=!catalog.complimentaryEnabled || me.sources.includes("complimentary");
  el("products").replaceChildren();
  if(!payload.products.length){for(const p of catalog.products){const row=document.createElement("div");row.className="product";const text=document.createElement("p");text.textContent=p.title+" · "+p.amount.toLocaleString("ko-KR")+"원"+(p.recurring?" / "+intervalLabel(p)+" · 자동 갱신":" · 한 번 결제");const button=document.createElement("button");button.textContent="구매하기";button.onclick=()=>action(()=>purchase(p));row.append(text,button);el("products").append(row);} for(const p of catalog.paypal?.products || []){const row=document.createElement("div");row.className="product";const text=document.createElement("p");text.textContent=paypalDescription(p);const button=document.createElement("button");button.textContent="PayPal로 결제";button.onclick=()=>action(()=>purchasePayPal(p));row.append(text,button);el("products").append(row);} if(!catalog.products.length&&!catalog.paypal?.products.length)el("products").textContent="이용권 판매를 준비하고 있습니다.";}
  const subscriptions=await api("subscriptions");el("subscriptions").replaceChildren();
  for(const s of subscriptions.subscriptions){const row=document.createElement("p");row.textContent=(s.product==="smooth_yearly"?"연간 구독":"월 구독")+" · "+s.amount.toLocaleString("ko-KR")+"원 · "+(s.cancelled?"자동 갱신 해지됨":"다음 결제 예정: "+new Date(s.nextDue*1000).toLocaleDateString("ko-KR"));if(!s.cancelled){const b=document.createElement("button");b.textContent="자동 갱신 해지";b.onclick=()=>action(async()=>{if(confirm("다음 자동결제를 중단할까요? 이미 결제한 기간까지 사용할 수 있습니다.")){await api("subscriptions/"+encodeURIComponent(s.id)+"/cancel",{});await showAccount();}});row.append(b);}el("subscriptions").append(row);}
  if(!subscriptions.subscriptions.length)el("subscriptions").textContent="토스 정기 결제가 없습니다.";
  await showPayPalHistory();
  await loadProviders();
}
const paypalDescription = p => (p.id === "smooth_yearly" ? "1년 이용권" : "평생 이용권") + " · US$" + (p.amount/100).toFixed(2) + " · 한 번 결제 · 자동 갱신 없음";
async function purchasePayPal(product){
  if(!confirm(paypalDescription(product)+"\n\nPayPal은 해외 고객용 결제입니다. 이용약관·환불 안내와 기기 호환성을 확인했고 위 금액의 결제에 동의하나요?"))return;
  const order=await api("paypal/orders",{product:product.id,amount:product.amount,termsVersion:catalog.termsVersion});
  if(order.completed){await showAccount();message("이용권이 적용되었습니다. 앱에서 ‘이용권 다시 확인’을 눌러 주세요.");return;}
  if(order.approved){await completePayPal(order.orderId);return;}
  const url=new URL(order.approvalURL), host=catalog.paypal.environment==="sandbox"?"www.sandbox.paypal.com":"www.paypal.com";
  if(url.protocol!=="https:"||url.hostname!==host||url.username||url.password||(url.port&&url.port!=="443"))throw new Error("PayPal 결제 주소를 확인하지 못했습니다.");
  sessionStorage.setItem("smooth-paypal-order",order.orderId);
  location.assign(url.href);
}
async function completePayPal(id){
  const result=await api("paypal/orders/"+encodeURIComponent(id)+"/capture",{});
  await showAccount();
  message(result.status==="done"?"PayPal 결제와 이용권 발급을 확인했습니다. 앱에서 ‘이용권 다시 확인’을 눌러 주세요.":result.status==="cancelled"?"취소·환불된 결제입니다.":"PayPal에서 결제를 확인 중입니다. 잠시 후 주문의 ‘결제 확인’을 눌러 주세요.");
}
async function showPayPalHistory(){
  const container=el("paypal-orders");container.replaceChildren();
  const {orders}=await api("paypal/orders");
  el("paypal-history").hidden=!orders.length;
  for(const order of orders){
    const row=document.createElement("div"), text=document.createElement("p");row.className="product";
    text.textContent=paypalDescription({...order,id:order.product})+" · "+({done:"결제 완료",cancelled:"취소·환불",created:"승인 대기",pending:"결제 확인 중"}[order.status]||order.status);row.append(text);
    if(["created","pending"].includes(order.status)){const button=document.createElement("button");button.textContent="결제 확인";button.onclick=()=>action(()=>completePayPal(order.id));row.append(button);}
    if(catalog.environment==="test"&&order.status==="done"){const button=document.createElement("button");button.textContent="테스트 결제 환불";button.onclick=()=>action(async()=>{if(confirm("테스트 결제를 환불하고 이용권을 회수할까요?")){await api("paypal/orders/"+encodeURIComponent(order.id)+"/refund",{});await showAccount();message("PayPal 환불 상태를 확인했습니다.");}});row.append(button);}
    container.append(row);
  }
}
async function purchase(product){
  if(!window.TossPayments)throw new Error("결제창을 불러오지 못했습니다. 다시 시도해 주세요.");
  const description=product.title+" · "+product.amount.toLocaleString("ko-KR")+"원 (부가세 포함)\n"+(product.recurring?"등록 후 첫 결제가 진행되고 "+renewalLabel(product)+" 자동 갱신됩니다. 다음 갱신 전 이 페이지에서 해지할 수 있으며, 이미 결제한 기간은 유지됩니다.":"한 번 결제하며 자동 갱신되지 않습니다.");
  if(!confirm(description+"\n\n이용약관·환불 안내와 기기 호환성을 확인했고, 위 금액으로 결제를 진행하는 데 동의하나요?"))return;
  const order=await api("orders",{product:product.id,...(catalog.termsVersion?{amount:product.amount,termsVersion:catalog.termsVersion}:{})});sessionStorage.setItem("smooth-order",JSON.stringify(order));
  const payment=TossPayments(order.clientKey).payment({customerKey:order.customerKey});
  const successUrl=location.origin+"/?flow="+(product.recurring?"billing":"payment"), failUrl=location.origin+"/?flow=failed";
  if(product.recurring)await payment.requestBillingAuth({method:"CARD",successUrl,failUrl});
  else await payment.requestPayment({method:"CARD",amount:{currency:"KRW",value:order.amount},orderId:order.orderId,orderName:"Smooth Player 평생 이용권",successUrl,failUrl});
}
async function finishPayment(){
  const q=new URLSearchParams(location.search), flow=q.get("flow");if(!flow)return;
  if(flow==="paypal-cancel"){history.replaceState(null,"",location.pathname);sessionStorage.removeItem("smooth-paypal-order");message("PayPal 결제를 취소했습니다. 이용권은 발급되지 않았습니다.");return;}
  if(flow==="failed"){history.replaceState(null,"",location.pathname);message("결제가 취소되었거나 완료되지 않았습니다.");return;}
  if(!session){message("결제한 이메일 계정으로 로그인해 결제를 완료해 주세요.");return;}
  if(flow==="paypal"){
    const id=q.get("order");if(!id)throw new Error("PayPal 주문을 찾을 수 없습니다.");
    await completePayPal(id);history.replaceState(null,"",location.pathname);sessionStorage.removeItem("smooth-paypal-order");return;
  }
  const order=JSON.parse(sessionStorage.getItem("smooth-order")||"null");if(!order)throw new Error("원래 결제한 브라우저에서 다시 확인해 주세요.");
  if(flow==="payment")await api("payments/confirm",{orderId:q.get("orderId"),paymentKey:q.get("paymentKey"),amount:Number(q.get("amount"))});
  else if(flow==="billing")await api("billing/confirm",{orderId:order.orderId,authKey:q.get("authKey"),customerKey:q.get("customerKey")});
  history.replaceState(null,"",location.pathname);sessionStorage.removeItem("smooth-order");await showAccount();message("이용권이 적용되었습니다. 앱에서 ‘다시 확인’을 눌러 주세요.");
}
action(async()=>{catalog=await api("catalog");el("environment").textContent=catalog.environment==="test"?"테스트 결제 환경 · 실제 요금이 청구되지 않습니다.":"";for(const p of catalog.offers||[]){const row=document.createElement("p");row.textContent=p.title+" · "+p.amount.toLocaleString("ko-KR")+"원"+(p.recurring?" / "+intervalLabel(p)+" · 자동 갱신":" · 한 번 결제")+(p.available?"":" · 판매 준비 중");el("offers").append(row);}for(const p of catalog.paypal?.products||[]){const row=document.createElement("p");row.textContent="해외 PayPal · "+paypalDescription(p);el("offers").append(row);}for(const [title,url] of Object.entries(catalog.links||{})){if(!url.startsWith("https://"))continue;const a=document.createElement("a");a.href=url;a.textContent=title;a.style.marginRight="16px";el("links").append(a);}for(const [title,value] of Object.entries(catalog.seller||{})){if(!value)continue;const row=document.createElement("p");row.textContent=title+": "+value;el("seller").append(row);}try{await completeSocial();}catch(e){message(e.message);}await loadProviders();if(session)await showAccount();await finishPayment();});

async function loadProviders() {
  providers = (await api("auth/providers")).providers;
  for (const target of ["social-login", "social-links"]) {
    const container = el(target); container.replaceChildren();
    for (const provider of providers.filter(p => ["google", "apple"].includes(p.id))) {
      const button = document.createElement("button"); button.className = "social " + provider.id;
      const title = provider.id === "google" ? "Google" : "Apple";
      if (provider.id === "google") { const icon = document.createElement("img"); icon.src="/google-login.png"; icon.alt=""; icon.width=20; icon.height=20; button.append(icon); }
      button.append(document.createTextNode(title + (provider.linked ? " 연결됨" : session ? " 연결" : "로 로그인")));
      button.dataset.unavailable = String(!provider.enabled || provider.linked);
      button.disabled = working || !provider.enabled || provider.linked;
      button.onclick = () => action(() => beginSocial(provider.id)); container.append(button);
    }
    if (providers.some(p => !p.enabled)) { const note = document.createElement("p"); note.className="muted"; note.textContent="비활성화된 로그인 방식은 준비 중입니다. 이메일 로그인을 이용할 수 있습니다."; container.append(note); }
  }
}
const base64url = bytes => btoa(String.fromCharCode(...bytes)).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/g,"");
async function beginSocial(provider) {
  const verifier = base64url(crypto.getRandomValues(new Uint8Array(48)));
  const challenge = base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
  const result = await api("auth/social/start", {provider, challenge, client:"web"});
  const expected = location.origin + "/v1/auth/social/browser/" + encodeURIComponent(result.id);
  if (result.authorizationURL !== expected) throw new Error("로그인 주소를 확인하지 못했습니다.");
  sessionStorage.setItem("smooth-social", JSON.stringify({id:result.id, verifier, expiresAt:result.expiresAt, owner:session?.userId || null, previousSearch:location.search}));
  location.assign(expected);
}
async function completeSocial() {
  if (new URLSearchParams(location.search).get("social") !== "complete") return;
  const pending = JSON.parse(sessionStorage.getItem("smooth-social") || "null");
  history.replaceState(null, "", location.pathname);
  if (!pending || pending.expiresAt <= Date.now()/1000 || pending.owner !== (session?.userId || null)) throw new Error("로그인을 시작한 브라우저에서 다시 시도해 주세요.");
  sessionStorage.removeItem("smooth-social");
  const result = await api("auth/social/complete", {id:pending.id, verifier:pending.verifier});
  if (result.status !== "complete" || !result.session || (pending.owner && result.session.userId !== pending.owner)) throw new Error("로그인을 완료하지 못했습니다.");
  session = result.session; sessionStorage.setItem("smooth-session", JSON.stringify(session));
  if (pending.previousSearch?.startsWith("?") && !new URLSearchParams(pending.previousSearch).has("social")) history.replaceState(null, "", location.pathname + pending.previousSearch);
  message(pending.owner ? "로그인 방식을 기존 계정에 연결했습니다." : "로그인했습니다.");
}
