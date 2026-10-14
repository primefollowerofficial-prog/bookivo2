export type Product = { id:string; title:string; slug:string; shortDescription:string; description:string; category:string; tags:string[]; price:number; listPrice:number; cover:string; benefits:string[]; checks:string[]; status:'draft'|'published'; featured:boolean };
export type CartLine = { product:Product; quantity:number };
export type Promotion = { enabled:boolean; message:string; start:string; expiry:string; popup:boolean; image:string };
