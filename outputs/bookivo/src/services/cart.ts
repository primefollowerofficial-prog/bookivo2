import type { CartLine, Product } from '../types';
const KEY='bookivo-cart';
export const readCart=():CartLine[]=>{try{return JSON.parse(localStorage.getItem(KEY)||'[]')}catch{return[]}};
export const writeCart=(cart:CartLine[])=>localStorage.setItem(KEY,JSON.stringify(cart));
export const addCart=(cart:CartLine[],product:Product)=>{const found=cart.find(x=>x.product.id===product.id);return found?cart.map(x=>x.product.id===product.id?{...x,product,quantity:Math.min(10,x.quantity+1)}:x):[...cart,{product,quantity:1}]};
