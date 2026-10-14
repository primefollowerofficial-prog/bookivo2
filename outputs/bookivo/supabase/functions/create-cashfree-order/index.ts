import { authenticate } from '../_shared/auth.ts';
import { cashfreeBase, cashfreeHeaders } from '../_shared/cashfree.ts';
import { body, env, json, preflight } from '../_shared/http.ts';

Deno.serve(async req => {
  const options = preflight(req); if (options) return options;
  if (req.method !== 'POST') return json({ error:'Method not allowed.' },405);
  try {
    const { admin,user } = await authenticate(req); const input = await body(req);
    if (!Array.isArray(input.items) || input.items.length<1 || input.items.length>20) return json({error:'Add between 1 and 20 books.'},400);
    const items = input.items.map((x: any) => ({ product_id:String(x.product_id||''),quantity:Number(x.quantity) }));
    if (items.some((x: any) => !/^[0-9a-f-]{36}$/i.test(x.product_id)||!Number.isInteger(x.quantity)||x.quantity<1||x.quantity>10)) return json({error:'Invalid checkout items.'},400);
    const email = user.email || '';
    const { data: order, error } = await admin.rpc('create_checkout_order',{p_user_id:user.id,p_idempotency_key:input.idempotency_key,p_items:items,p_customer_name:input.customer_name,p_customer_email:email,p_customer_phone:input.customer_phone,p_coupon_code:input.coupon_code||null});
    if (error) throw new Error(error.message);
    const gatewayOrderId = `bivo_${String(order.id).replaceAll('-','')}`;
    let session = order.payment_session_id;
    if (!session) {
      const amount = (Number(order.amount_due_paise)/100).toFixed(2);
      const appUrl = env('APP_URL').replace(/\/$/,'');
      const response = await fetch(`${cashfreeBase()}/orders`,{method:'POST',headers:{...cashfreeHeaders(),'x-idempotency-key':String(input.idempotency_key)},body:JSON.stringify({order_id:gatewayOrderId,order_amount:Number(amount),order_currency:'INR',customer_details:{customer_id:user.id.replaceAll('-','').slice(0,50),customer_name:input.customer_name,customer_email:email,customer_phone:input.customer_phone},order_meta:{return_url:`${appUrl}/checkout/success?order_id=${gatewayOrderId}`,notify_url:`${env('SUPABASE_URL')}/functions/v1/cashfree-webhook`},order_note:`Bookivo ${order.order_number}`})});
      const result=await response.json(); if(!response.ok||!result.payment_session_id) throw new Error(result.message||'Cashfree could not start checkout.');
      session=result.payment_session_id;
      const {data:attached,error:attachError}=await admin.rpc('attach_cashfree_session',{p_order_id:order.id,p_gateway_order_id:gatewayOrderId,p_payment_session_id:session});
      if(attachError||!attached) throw new Error('Could not attach the secure payment session.');
    }
    return json({order_id:gatewayOrderId,local_order_id:order.id,payment_session_id:session,environment:Deno.env.get('CASHFREE_ENV')==='production'?'production':'sandbox',amount_paise:order.amount_due_paise,currency:'INR'});
  } catch(e) { return json({error:e instanceof Error?e.message:'Could not create payment order.'},400); }
});
