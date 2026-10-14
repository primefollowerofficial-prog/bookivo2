import { authenticate } from '../_shared/auth.ts';
import { body, json, preflight } from '../_shared/http.ts';
Deno.serve(async req=>{
 const options=preflight(req);if(options)return options;if(req.method!=='POST')return json({error:'Method not allowed.'},405);
 try{
  const {admin,user}=await authenticate(req),input=await body(req),productId=String(input.product_id||'');if(!/^[0-9a-f-]{36}$/i.test(productId))return json({error:'Invalid book.'},400);
  const {data:entitlement,error}=await admin.from('purchase_entitlements').select('id,order:orders!inner(status),product:products!inner(title,ebook_object_path)').eq('user_id',user.id).eq('product_id',productId).is('revoked_at',null).eq('order.status','paid').single();
  if(error||!entitlement)return json({error:'A completed purchase is required to download this book.'},403);
  const product=entitlement.product as any;if(!product.ebook_object_path)return json({error:'The publisher has not uploaded this ebook yet.'},409);
  const filename=`${String(product.title).replace(/[^a-z0-9 _-]/gi,'').trim().slice(0,80)||'Bookivo-ebook'}.pdf`;
  const {data:signed,error:signError}=await admin.storage.from('paid-ebooks').createSignedUrl(product.ebook_object_path,60,{download:filename});if(signError||!signed?.signedUrl)throw new Error('Could not create a secure download link.');
  const {error:auditError}=await admin.from('download_events').insert({user_id:user.id,product_id:productId,entitlement_id:entitlement.id});if(auditError)throw new Error('Could not record the download request.');return json({signed_url:signed.signedUrl,expires_in:60,filename});
 }catch(e){return json({error:e instanceof Error?e.message:'Download could not be prepared.'},400);}
});
