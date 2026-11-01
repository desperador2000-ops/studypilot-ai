import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
const systemPrompt=`Tu es StudyPilot Tutor AI, un professeur particulier patient, rigoureux et pédagogique. Ton but est de faire comprendre, pas seulement de donner la réponse. Adapte ton vocabulaire au niveau et à la matière. Explique avec des étapes numérotées, les formules et calculs utiles, un exemple concret et une vérification du résultat. Pour les mathématiques, présente données, formule, substitution, calculs et unité. Pour les langues, explique les corrections et règles. Pour les images, ne lis que ce qui est visible, signale les parties illisibles et ne devine jamais l'énoncé. Si l'image est floue, demande une nouvelle photo. Signale toute incertitude. Réponds en français sauf demande contraire. Termine si pertinent par une question de compréhension.`;
Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return json({error:"Méthode non autorisée."},405);
 const apiKey=Deno.env.get("GEMINI_API_KEY"),model=Deno.env.get("GEMINI_MODEL")||"gemini-2.5-flash",url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!;
 if(!apiKey)return json({error:"Configuration requise : clé Gemini absente côté serveur."},503);
 const auth=req.headers.get("Authorization");if(!auth?.startsWith("Bearer "))return json({error:"Connexion requise."},401);
 const sb=createClient(url,anon,{global:{headers:{Authorization:auth}}});
 const {data:{user},error:ue}=await sb.auth.getUser();if(ue||!user)return json({error:"Session invalide."},401);
 try{
 const body=await req.json(),conversationId=String(body.conversation_id||""),message=String(body.message||"").slice(0,12000),path=body.attachment_path?String(body.attachment_path):null,subject=String(body.subject||"Autre").slice(0,80),level=String(body.education_level||"Lycée").slice(0,80);
 if(!conversationId||(!message&&!path))return json({error:"Question ou photo manquante."},400);
 const {data:conv,error:ce}=await sb.from("tutor_conversations").select("id").eq("id",conversationId).eq("user_id",user.id).single();if(ce||!conv)return json({error:"Conversation introuvable."},404);
 if(path&&!path.startsWith(user.id+"/"))return json({error:"Pièce jointe non autorisée."},403);
 let imagePart:Record<string,unknown>|null=null;
 if(path){const {data:file,error:fe}=await sb.storage.from("tutor-attachments").download(path);if(fe||!file)return json({error:"Photo introuvable."},400);if(file.size>5*1024*1024)return json({error:"Photo trop volumineuse."},413);const type=file.type;if(!["image/jpeg","image/png","image/webp"].includes(type))return json({error:"Format d'image refusé."},415);const bytes=new Uint8Array(await file.arrayBuffer());let binary="";for(let i=0;i<bytes.length;i+=0x8000)binary+=String.fromCharCode(...bytes.subarray(i,i+0x8000));imagePart={inline_data:{mime_type:type,data:btoa(binary)}};}
 const {data:history}=await sb.from("tutor_messages").select("role,content").eq("conversation_id",conversationId).order("created_at",{ascending:false}).limit(12);
 const parts:any[]=[{text:systemPrompt+"\nMatière : "+subject+". Niveau : "+level+"."}];
 const contentParts:any[]=[];if(message)contentParts.push({text:message});if(imagePart)contentParts.push(imagePart);
 const contents=[...(history||[]).reverse().map((m:any)=>({role:m.role==="assistant"?"model":"user",parts:[{text:m.content}]})),{role:"user",parts:contentParts}];
 const response=await fetch("https://generativelanguage.googleapis.com/v1beta/models/"+encodeURIComponent(model)+":generateContent?key="+encodeURIComponent(apiKey),{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({system_instruction:{parts},contents,generationConfig:{temperature:0.35,maxOutputTokens:1800}})});
 if(response.status===429)return json({error:"Limite gratuite du fournisseur atteinte. Réessaie plus tard."},429);
 if(!response.ok){const status=response.status;return json({error:status===400?"La requête n'a pas pu être traitée.":status===403?"Accès au modèle refusé. Vérifie la clé et les autorisations.":"Le professeur IA est momentanément indisponible."},502);}
 const payload=await response.json(),answer=payload?.candidates?.[0]?.content?.parts?.map((p:any)=>p.text||"").join("\n").trim();
 if(!answer)return json({error:"Le modèle n'a pas fourni de réponse exploitable."},502);
 const {data:saved,error:se}=await sb.from("tutor_messages").insert({conversation_id:conversationId,user_id:user.id,role:"assistant",content:answer}).select("id").single();if(se)return json({error:"Réponse générée, mais impossible de l'enregistrer."},500);
 await sb.from("tutor_conversations").update({updated_at:new Date().toISOString()}).eq("id",conversationId).eq("user_id",user.id);
 return json({answer,message_id:saved.id});
 }catch(_e){return json({error:"Une erreur inattendue est survenue. Réessaie."},500)}
});