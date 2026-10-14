import { createClient } from 'npm:@supabase/supabase-js@2';
import { cashfreeBase, cashfreeHeaders } from '../_shared/cashfree.ts';
import { env, json, paise, sha256 } from '../_shared/http.ts';
import { sendOrderConfirmation } from '../_shared/email.ts';

async function validSignature(secret:string,timestamp:string,raw:string,signature:string){
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 const digest=await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(timestamp+raw));const expected=btoa(String.fromCharCode(...new Uint8Array(digest)));
 if(expected.length!==signature.length)return false;let diff=0;for(let i=0;i<expected.length;i++)diff|=expected.charCodeAt(i)^signature.charCodeAt(i);return diff===0;
}
Deno.serve(async req=>{
 if(req.method!=='POST')return json({error:'Method not allowed.'},405,false);
 try{
  const raw=await req.text(),signature=req.headers.get('x-webhook-signature')||'',timestamp=req.headers.get('x-webhook-timestamp')||'';
  // Cashfree timestamp units can vary across account integrations; authenticate the exact signed header/body
  // and separately confirm the payment against Cashfree's API. Event idempotency prevents replay fulfillment.
  if(!signature||!timestamp||!(await validSignature(env('CASHFREE_SECRET_KEY'),timestamp,raw,signature)))return json({error:'Invalid webhook signature.'},401,false);
  const event=JSON.parse(raw),detail=event.data?.payment||{},gatewayId=event.data?.order?.order_id||detail.order_id;
  if(!gatewayId||!detail.cf_payment_id)return json({error:'Malformed payment event.'},400,false);
  const admin=createClient(env('SUPABASE_URL'),env('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false}});
  // Confirm successful webhook claims against Cashfree's authenticated order and payment APIs before granting access.
  const [orderResp,paymentsResp]=await Promise.all([fetch(`${cashfreeBase()}/orders/${encodeURIComponent(gatewayId)}`,{headers:cashfreeHeaders()}),fetch(`${cashfreeBase()}/orders/${encodeURIComponent(gatewayId)}/payments`,{headers:cashfreeHeaders()})]);
  const remote=await orderResp.json(),payments=await paymentsResp.json();if(!orderResp.ok||!paymentsResp.ok)throw new Error('Could not confirm payment with Cashfree.');
  const payment=(Array.isArray(payments)?payments:[]).find((p:any)=>String(p.cf_payment_id)===String(detail.cf_payment_id));if(!payment)throw new Error('Payment not found at Cashfree.');
  const {data:order}=await admin.from('orders').select('id').eq('gateway_order_id',gatewayId).single();if(!order)return json({error:'Unknown order.'},404,false);
  const digest=await sha256(raw);const processed=await admin.rpc('process_cashfree_payment',{p_gateway_order_id:gatewayId,p_cf_payment_id:String(payment.cf_payment_id),p_event_key:`webhook:${event.type||'payment'}:${payment.cf_payment_id}:${payment.payment_status}`,p_event_type:String(event.type||'PAYMENT'),p_payment_status:payment.payment_status,p_amount_paise:paise(payment.payment_amount),p_currency:payment.payment_currency,p_payload_sha256:digest});if(processed.error)throw new Error(processed.error.message);
  if(remote.order_status==='PAID'&&payment.payment_status==='SUCCESS')await sendOrderConfirmation(admin,order.id);
  return json({received:true},200,false);
 }catch(e){return json({error:e instanceof Error?e.message:'Webhook processing failed.'},400,false);}
});
