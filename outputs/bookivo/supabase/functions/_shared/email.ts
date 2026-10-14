import { env } from './http.ts';

const escapeHtml = (s: string) => s.replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' })[c]!);
export async function sendOrderConfirmation(admin: any, orderId: string) {
  if (!Deno.env.get('BREVO_API_KEY') || !Deno.env.get('BREVO_SENDER_EMAIL')) return;
  const { data: claimed, error: claimError } = await admin.rpc('claim_order_confirmation_email', { p_order_id: orderId });
  if (claimError || !claimed) return;
  try {
    const { data: order, error } = await admin.from('orders').select('order_number,customer_name,customer_email,amount_due_paise,currency,order_items(title_snapshot,quantity)').eq('id', orderId).single();
    if (error || !order) throw new Error('order_lookup_failed');
    const rows = (order.order_items || []).map((i: any) => `<li>${escapeHtml(i.title_snapshot)} × ${i.quantity}</li>`).join('');
    const response = await fetch('https://api.brevo.com/v3/smtp/email', { method:'POST', headers:{'api-key':env('BREVO_API_KEY'),'content-type':'application/json'}, body:JSON.stringify({
      sender:{email:env('BREVO_SENDER_EMAIL'),name:Deno.env.get('BREVO_SENDER_NAME')||'Bookivo'}, to:[{email:order.customer_email,name:order.customer_name}], subject:`Your Bookivo order ${order.order_number} is confirmed`,
      htmlContent:`<h1>Thank you, ${escapeHtml(order.customer_name)}</h1><p>Your payment is confirmed.</p><p>Order ${escapeHtml(order.order_number)}</p><ul>${rows}</ul><p>Total paid: ₹${(order.amount_due_paise/100).toFixed(2)}</p><p>Your purchased books are ready in your Bookivo library.</p>`,
    }) });
    if (!response.ok) throw new Error(`brevo_http_${response.status}`);
    await admin.rpc('finish_order_confirmation_email', { p_order_id:orderId,p_sent:true,p_error_code:null });
  } catch (e) { await admin.rpc('finish_order_confirmation_email', { p_order_id:orderId,p_sent:false,p_error_code:String(e).slice(0,40) }); }
}
