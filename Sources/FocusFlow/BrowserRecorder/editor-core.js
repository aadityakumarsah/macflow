(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.EditorCore=api;})(globalThis,()=>{
'use strict';
const clamp=(v,a,b)=>Math.min(b,Math.max(a,Number.isFinite(Number(v))?Number(v):a));
const ease=t=>{t=clamp(t,0,1);return t*t*t*(t*(t*6-15)+10);};
const kinds=['zoom','pan','blur','spotlight','callout','cursor'];
function region(r={}){const width=clamp(r.width??1,.05,1),height=clamp(r.height??1,.05,1);return{x:clamp(r.x??0,0,1-width),y:clamp(r.y??0,0,1-height),width,height};}
function defaults(duration=1){return{version:1,name:'Untitled demo',trimStart:0,trimEnd:duration,speed:1,muted:false,ratio:'source',background:'aurora',padding:7,corners:18,shadow:30,frame:'light',title:'',lights:true,barHeight:52,entrance:'none',transition:.8,fadeOut:false,crop:region(),camera:{show:true,x:.82,y:.78,size:.24,shape:'circle',mirror:true},cursor:{show:true,size:1,shape:'auto',clicks:true},segments:[]};}
function sanitize(input,duration){
 const s={...defaults(duration),...input};s.name=String(s.name).slice(0,100);s.title=String(s.title).slice(0,100);
 s.trimStart=clamp(s.trimStart,0,Math.max(0,duration-.05));s.trimEnd=clamp(s.trimEnd,s.trimStart+.05,duration);s.speed=clamp(s.speed,.25,3);
 s.padding=clamp(s.padding,0,20);s.corners=clamp(s.corners,0,60);s.shadow=clamp(s.shadow,0,60);s.barHeight=clamp(s.barHeight,28,90);s.transition=clamp(s.transition,.1,3);s.crop=region(s.crop);
 for(const [key,values] of Object.entries({ratio:['source','16:9','9:16','1:1','4:3'],background:['aurora','ocean','graphite','cream','none'],frame:['none','light','dark'],entrance:['none','rise','slide','scale']}))if(!values.includes(s[key]))s[key]=defaults(duration)[key];
 s.camera={...defaults().camera,...s.camera};for(const key of ['x','y'])s.camera[key]=clamp(s.camera[key],0,1);s.camera.size=clamp(s.camera.size,.12,.45);
 s.cursor={...defaults().cursor,...s.cursor};s.cursor.size=clamp(s.cursor.size,.5,2.5);
 s.segments=(Array.isArray(s.segments)?s.segments:[]).filter(v=>v&&kinds.includes(v.kind)).slice(0,500).map((v,i)=>{
  const start=clamp(v.start,0,Math.max(0,duration-.1));return{...v,id:String(v.id||`effect-${i}`).slice(0,80),start,duration:clamp(v.duration,.1,duration-start),intensity:clamp(v.intensity??1.7,1,3),transition:clamp(v.transition??.7,.1,2),x:clamp(v.x??.5,0,1),y:clamp(v.y??.5,0,1),endX:clamp(v.endX??.7,0,1),endY:clamp(v.endY??.5,0,1),width:clamp(v.width??.3,.02,1),height:clamp(v.height??.2,.02,1),text:String(v.text??'Look here').slice(0,100),shape:v.shape==='text'?'text':'arrow'};
 });return s;
}
function envelope(s,t){const edge=Math.min(s.transition??.7,s.duration/2);return ease(Math.min((t-s.start)/edge,(s.start+s.duration-t)/edge));}
function sample(points,t){if(!points?.length||t<points[0].time)return null;let lo=0,hi=points.length;while(lo<hi){const mid=(lo+hi)>>1;if(points[mid].time<=t)lo=mid+1;else hi=mid;}const a=points[Math.max(0,lo-1)],b=points[lo];if(!b)return t-a.time<.2?a:null;if(b.time-a.time>.2)return null;const u=clamp((t-a.time)/(b.time-a.time),0,1);return{x:a.x+(b.x-a.x)*u,y:a.y+(b.y-a.y)*u,shape:a.shape==='Text (I-beam)'?'text':'arrow'};}
function viewport(segments,t,crop,points=[]){let w=0,z=0,x=0,y=0;for(const s of segments){if(s.kind!=='zoom'&&s.kind!=='pan')continue;const e=envelope(s,t);if(!e)continue;let px=s.x,py=s.y;if(s.kind==='pan'){const u=ease((t-s.start)/s.duration);px+=(s.endX-px)*u;py+=(s.endY-py)*u;}else if(s.follow){const p=sample(points,t);if(p){px=p.x;py=p.y;}}w+=e;z+=(s.intensity-1)*e;x+=(px-crop.x)/crop.width*e;y+=(py-crop.y)/crop.height*e;}if(!w)return{x:0,y:0,width:1,height:1};const size=1/(1+z/Math.max(1,w));return{x:clamp(x/w-size/2,0,1-size),y:clamp(y/w-size/2,0,1-size),width:size,height:size};}
function outputSize(w,h,s){const c=s.crop;let aspect=w*c.width/(h*c.height);if(s.frame!=='none')aspect=1/(1/aspect+s.barHeight/1920);if(s.ratio!=='source'){const [a,b]=s.ratio.split(':').map(Number);aspect=a/b;}let width=aspect>=1?1920:Math.round(1080*aspect),height=aspect>=1?Math.round(1920/aspect):1080;return{width:Math.max(2,Math.round(width/2)*2),height:Math.max(2,Math.round(height/2)*2)};}
function layout(w,h,sw,sh,s){const pad=Math.min(w,h)*s.padding/100,aspect=sw*s.crop.width/(sh*s.crop.height),bar=s.frame==='none'?0:s.barHeight/1920;const width=Math.min(w-2*pad,(h-2*pad)/(1/aspect+bar)),height=width/aspect,header=width*bar;return{x:(w-width)/2,y:(h-height-header)/2,width,height:height+header,contentY:(h-height-header)/2+header,contentHeight:height,header};}
function mapPoint(px,py,l,v,c){return{x:c.x+(v.x+(px-l.x)/l.width*v.width)*c.width,y:c.y+(v.y+(py-l.contentY)/l.contentHeight*v.height)*c.height};}
function rounded(ctx,x,y,w,h,r){ctx.beginPath();ctx.roundRect(x,y,Math.max(.01,w),Math.max(.01,h),Math.min(r,Math.max(.01,w)/2,Math.max(.01,h)/2));}
function draw(ctx,video,time,s,assets={},camera=null,metadata={}){
 const W=ctx.canvas.width,H=ctx.canvas.height,sw=video.videoWidth||video.width,sh=video.videoHeight||video.height;if(!sw||!sh)return;
 const palettes={aurora:['#6156db','#e995d4','#ffb57c'],ocean:['#10235b','#4977db','#91e0e4'],graphite:['#303745','#13171f','#070b12'],cream:['#f4e5cd','#fff8ea','#edc4a1'],none:['#080a0c','#080a0c','#080a0c']};
 const colors=palettes[s.background]||palettes.aurora,gradient=ctx.createLinearGradient(0,0,W,H);colors.forEach((color,i)=>gradient.addColorStop(i/2,color));ctx.fillStyle=gradient;ctx.fillRect(0,0,W,H);
 const l=layout(W,H,sw,sh,s),v=viewport(s.segments,time,s.crop,metadata.pointerSamples),crop=s.crop;
 const sx=(crop.x+v.x*crop.width)*sw,sy=(crop.y+v.y*crop.height)*sh,cw=crop.width*v.width*sw,ch=crop.height*v.height*sh;
 const point=(x,y)=>({x:l.x+(x*sw-sx)/cw*l.width,y:l.contentY+(y*sh-sy)/ch*l.contentHeight});
 ctx.save();const intro=ease((time-s.trimStart)/s.transition);
 if(s.entrance!=='none'){ctx.globalAlpha=intro;if(s.entrance==='rise')ctx.translate(0,(1-intro)*H*.12);if(s.entrance==='slide')ctx.translate(-(1-intro)*W*.16,0);if(s.entrance==='scale'){const z=.9+intro*.1;ctx.translate(W/2,H/2);ctx.scale(z,z);ctx.translate(-W/2,-H/2);}}
 if(s.fadeOut)ctx.globalAlpha*=ease((s.trimEnd-time)/s.transition);
 ctx.shadowColor='#0007';ctx.shadowBlur=s.shadow;ctx.shadowOffsetY=s.shadow/3;ctx.fillStyle='#121619';rounded(ctx,l.x,l.y,l.width,l.height,s.corners);ctx.fill();ctx.shadowColor='transparent';ctx.shadowBlur=0;ctx.shadowOffsetY=0;ctx.clip();
 ctx.drawImage(video,sx,sy,cw,ch,l.x,l.contentY,l.width,l.contentHeight);
 ctx.save();ctx.beginPath();ctx.rect(l.x,l.contentY,l.width,l.contentHeight);ctx.clip();
 for(const effect of s.segments){if(time<effect.start||time>effect.start+effect.duration)continue;const p=point(effect.x,effect.y),ew=effect.width*sw/cw*l.width,eh=effect.height*sh/ch*l.contentHeight,e=envelope(effect,time);
  if(effect.kind==='blur'){ctx.save();ctx.beginPath();ctx.rect(p.x-ew/2,p.y-eh/2,ew,eh);ctx.clip();ctx.filter=`blur(${effect.intensity*10}px)`;ctx.drawImage(video,sx,sy,cw,ch,l.x,l.contentY,l.width,l.contentHeight);ctx.restore();}
  if(effect.kind==='spotlight'){ctx.save();ctx.fillStyle=`rgba(0,0,0,${e*effect.intensity*.25})`;ctx.beginPath();ctx.rect(l.x,l.contentY,l.width,l.contentHeight);ctx.roundRect(p.x-ew/2,p.y-eh/2,ew,eh,12);ctx.fill('evenodd');ctx.restore();}
  if(effect.kind==='callout'){ctx.save();ctx.globalAlpha*=e;const font=26*W/1920*effect.intensity;ctx.font=`600 ${font}px -apple-system, BlinkMacSystemFont, sans-serif`;const width=Math.min(l.width,ctx.measureText(effect.text).width+font*1.5),height=font*2.2,x=clamp(p.x-width/2,l.x,l.x+l.width-width),y=clamp(p.y-height/2,l.contentY,l.contentY+l.contentHeight-height);ctx.fillStyle='#12171ef2';rounded(ctx,x,y,width,height,font*.5);ctx.fill();ctx.fillStyle='#fff';ctx.textAlign='center';ctx.textBaseline='middle';ctx.fillText(effect.text,x+width/2,y+height/2,width-font);ctx.restore();}
 }
 if(s.cursor.clicks)for(const click of metadata.clicks||[]){const age=time-click.time;if(age<0||age>.6)continue;const p=point(click.x,click.y);ctx.save();ctx.globalAlpha*=1-age/.6;ctx.strokeStyle='#71b7ff';ctx.lineWidth=2*sw/cw;ctx.beginPath();ctx.arc(p.x,p.y,(8+35*ease(age/.6))*sw/cw,0,Math.PI*2);ctx.stroke();ctx.restore();}
 const manual=s.segments.filter(e=>e.kind==='cursor'&&time>=e.start&&time<=e.start+e.duration).at(-1);
 let pointer=sample(metadata.pointerSamples,time);
 if(manual){const u=ease((time-manual.start)/manual.duration);pointer={x:manual.x+(manual.endX-manual.x)*u,y:manual.y+(manual.endY-manual.y)*u,shape:manual.shape};}
 if(s.cursor.show&&pointer){const shape=s.cursor.shape==='auto'?pointer.shape:s.cursor.shape;const type=shape==='text'?'text':'arrow',img=assets[type],m=assets.metrics?.[type];if(img&&m){const p=point(pointer.x,pointer.y),scale=(metadata.sourcePointWidth?sw/metadata.sourcePointWidth:1)*l.width/cw*s.cursor.size;ctx.drawImage(img,p.x-m.hotX*scale,p.y-m.hotY*scale,m.width*scale,m.height*scale);}}
 ctx.restore();
 if(l.header){ctx.fillStyle=s.frame==='dark'?'#24272e':'#f5f5f7';ctx.fillRect(l.x,l.y,l.width,l.header);if(s.lights)['#ff5f57','#febc2e','#28c840'].forEach((color,i)=>{ctx.fillStyle=color;ctx.beginPath();ctx.arc(l.x+(28+i*25)*l.width/1920,l.y+l.header/2,7.5*l.width/1920,0,Math.PI*2);ctx.fill();});ctx.font=`500 ${20*l.width/1920}px -apple-system, sans-serif`;ctx.fillStyle=s.frame==='dark'?'#ccd0d7':'#62666d';ctx.textAlign='center';ctx.textBaseline='middle';ctx.fillText(s.title,l.x+l.width/2,l.y+l.header/2,l.width*.6);}
 ctx.restore();
 if(camera&&s.camera.show&&(camera.videoWidth||camera.width)){const c=s.camera,h=Math.min(W,H)*c.size,w=c.shape==='circle'?h:h*1.45,x=clamp(c.x*W-w/2,0,W-w),y=clamp(c.y*H-h/2,0,H-h),iw=camera.videoWidth||camera.width,ih=camera.videoHeight||camera.height,scale=Math.max(w/iw,h/ih);ctx.save();rounded(ctx,x,y,w,h,c.shape==='circle'?h/2:20);ctx.clip();if(c.mirror){ctx.translate(x*2+w,0);ctx.scale(-1,1);}ctx.drawImage(camera,x+(w-iw*scale)/2,y+(h-ih*scale)/2,iw*scale,ih*scale);ctx.restore();}
 return{layout:l,viewport:v};
}
return{clamp,ease,region,defaults,sanitize,envelope,sample,viewport,outputSize,layout,mapPoint,draw,kinds};
});
