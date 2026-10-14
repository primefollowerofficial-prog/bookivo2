import type { Product } from '../types';
// Used only as decorative artwork when no live product is available; never included in the public catalogue.
export let products: Product[] = [];
export function replaceProducts(next: Product[]) { products = next; }
export const previewProduct: Product = {id:'preview-only',title:'Useful Knowledge',slug:'useful-knowledge',shortDescription:'',description:'',category:'Bookivo',tags:[],price:0,listPrice:0,cover:'',benefits:[],checks:[],status:'draft',featured:false};
export const categories=['Lifestyle','Personal Growth','Career & Skills','Cooking & Everyday Life','Finance & Productivity'];
