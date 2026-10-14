import { authenticate } from '../_shared/auth.ts';
import { cashfreeBase, cashfreeHeaders } from '../_shared/cashfree.ts';
import { body, json, preflight, sha256, paise } from '../_shared/http.ts';
import { sendOrderConfirmation } from '../_shared/email.ts';

Deno.serve(async req=>{
 const options=preflight(req);if(options)return options;if(req.method!=='POST')return json({error:'Method not allowed.'},405);
 try{
  const {admin,user}=await authenticate(req);const input=await body(req);const gatewayId=String(input.gateway_order_id||'');
  if(!/^bivo_[0-9a-f]{32}$/i.test(gatewayId))return json({error:'Invalid order reference.'},400);
  const {data:order,error}=await admin.from('orders').select('id,gateway_order_id,amount_due_paise,currency,status').eq('gateway_order_id',gatewayId).eq('user_id',user.id).single();if(error||!order)return json({error:'Order not found.'},404);
  const [orderResp,paymentsResp]=await Promise.all([fetch(`${cashfreeBase()}/orders/${encodeURIComponent(gatewayId)}`,{headers:cashfreeHeaders()}),fetch(`${cashfreeBase()}/orders/${encodeURIComponent(gatewayId)}/payments`,{headers:cashfreeHeaders()})]);
  const remote=await orderResp.json(),payments=await paymentsResp.json();if(!orderResp.ok||!paymentsResp.ok)throw new Error('Payment status could not be verified.');
  const list=Array.isArray(payments)?payments:[];const payment=list.find((p:any)=>p.payment_status==='SUCCESS')||list[0];
  if(remote.order_status==='PAID'&&payment?.payment_status==='SUCCESS'){
   const digest=await sha256(JSON.stringify({remote,payment}));const processed=await admin.rpc('process_cashfree_payment',{p_gateway_order_id:gatewayId,p_cf_payment_id:String(payment.cf_payment_id),p_event_key:`verify:${payment.cf_payment_id}:SUCCESS`,p_event_type:'PAYMENT_STATUS_VERIFIED',p_payment_status:'SUCCESS',p_amount_paise:paise(payment.payment_amount),p_currency:payment.payment_currency,p_payload_sha256:digest});if(processed.error)throw new Error(processed.error.message);
   await sendOrderConfirmation(admin,order.id);return json({status:'paid',order_id:gatewayId});
  }
  if(payment&&['FAILED','USER_DROPPED'].includes(payment.payment_status)){const digest=await sha256(JSON.stringify({remote,payment}));const processed=await admin.rpc('process_cashfree_payment',{p_gateway_order_id:gatewayId,p_cf_payment_id:String(payment.cf_payment_id),p_event_key:`verify:${payment.cf_payment_id}:${payment.payment_status}`,p_event_type:'PAYMENT_STATUS_VERIFIED',p_payment_status:payment.payment_status,p_amount_paise:paise(payment.payment_amount),p_currency:payment.payment_currency,p_payload_sha256:digest});if(processed.error)throw new Error(processed.error.message);return json({status:'failed',order_id:gatewayId});}
  return json({status:remote.order_status==='EXPIRED'?'failed':'pending',order_id:gatewayId});
 }catch(e){return json({error:e instanceof Error?e.message:'Could not verify payment.'},400);}
});
