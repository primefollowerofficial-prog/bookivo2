import { authenticate, requireAdmin } from '../_shared/auth.ts';
import { body, json, preflight } from '../_shared/http.ts';
Deno.serve(async req=>{
 const options=preflight(req);if(options)return options;if(req.method!=='POST')return json({error:'Method not allowed.'},405);
 try{
  const {admin,user}=await authenticate(req);await requireAdmin(admin,user.id);const input=await body(req);
  if(input.action==='upload-ebook'){
   const productId=String(input.product_id||''),path=String(input.object_path||'');if(!/^[0-9a-f-]{36}$/i.test(productId)||!path.startsWith(`${productId}/`)||path.includes('..'))return json({error:'Invalid ebook path.'},400);
   const {error}=await admin.from('products').update({ebook_object_path:path}).eq('id',productId);if(error)throw error;return json({ok:true});
  }
  return json({error:'Unsupported administrative action.'},400);
 }catch(e){return json({error:e instanceof Error?e.message:'Administrator action failed.'},400);}
});
