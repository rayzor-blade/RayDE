// The embedded editor owns its window border and corners in every theme.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {createRequire} from 'node:module';
import {mkdir,writeFile} from 'node:fs/promises';
import {resolve,join} from 'node:path';
const root=resolve(import.meta.dirname,'../..'),shots=join(root,'bin/web/landing-chrome-shots');
const puppeteer=createRequire(join(root,'web/session/package.json'))('puppeteer-core');
await mkdir(shots,{recursive:true});
const service=spawn('python3',['scripts/serve-site.py','--port','0','--offline'],{cwd:root,stdio:['ignore','pipe','pipe']});
let browser;
const report=[];
try{
 const url=await new Promise((resolve,reject)=>{
  let output='',errors='';const timer=setTimeout(()=>reject(Error('Landing startup: '+errors)),20000);
  service.stderr.on('data',data=>{errors=(errors+data).slice(-4000);});
  service.once('exit',code=>{clearTimeout(timer);reject(Error('Landing exited: '+code+' '+errors));});
  service.stdout.on('data',data=>{output+=data;const match=output.match(/RayDE landing page: (http:\/\/\S+)/);if(match){clearTimeout(timer);resolve(match[1]);}});
 });
 browser=await puppeteer.launch({executablePath:process.env.CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--no-sandbox','--enable-unsafe-webgpu'],defaultViewport:{width:1440,height:1080}});
 for(const theme of ['hybrid','expressive'])for(const scheme of ['dark','light']){
  const context=await browser.createBrowserContext(),page=await context.newPage(),failures=[];
  try{
   page.on('pageerror',error=>failures.push(String(error)));
   await page.evaluateOnNewDocument(()=>Object.defineProperty(navigator,'hardwareConcurrency',{value:4}));
   await page.emulateMediaFeatures([{name:'prefers-color-scheme',value:scheme},{name:'prefers-reduced-motion',value:'reduce'}]);
   // Save appearance before the sample boots, without editing the live demo workspace.
   await page.goto(new URL('docs/',url));
   await page.evaluate(({theme,scheme})=>new Promise((resolve,reject)=>{
    const request=indexedDB.open('rayde-page',1);
    request.onupgradeneeded=()=>request.result.createObjectStore('files',{keyPath:'path'});
    request.onerror=()=>reject(request.error);
    request.onsuccess=()=>{
     const db=request.result,transaction=db.transaction('files','readwrite'),store=transaction.objectStore('files');
     store.put({path:'/work/pocket-studio/.rayde',directory:true,data:null});
     store.put({path:'/work/pocket-studio/.rayde/settings.json',directory:false,data:btoa(JSON.stringify({appearance:{theme,scheme}}))});
     transaction.oncomplete=()=>{db.close();resolve();};transaction.onerror=()=>{db.close();reject(transaction.error);};
    };
   }),{theme,scheme});
   await page.goto(url);
   await page.waitForFunction(()=>document.querySelector('#demo-state').hasAttribute('data-live'),{timeout:120000});
   const frame=await page.$('.editor-frame'),element=await page.$('#editor'),editor=await element.contentFrame();
   await frame.scrollIntoView();
   const decoration=await frame.evaluate(node=>{const s=getComputedStyle(node);return {border:s.borderTopWidth,radius:s.borderTopLeftRadius,clip:s.overflow,shadow:s.boxShadow,filter:s.filter};});
   assert.match(decoration.filter,/^drop-shadow\(/);
   assert.deepEqual({...decoration,filter:undefined},{border:'0px',radius:'0px',clip:'visible',shadow:'none',filter:undefined});
   assert.equal(await editor.evaluate(()=>document.documentElement.hasAttribute('data-embedded')),true);
   assert.equal(await editor.evaluate(()=>getComputedStyle(document.body).backgroundColor),'rgba(0, 0, 0, 0)');
   assert.equal(await page.$eval('.editor-poster',image=>image.hidden),true,'Poster still covers the transparent window corners');
   assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
   await frame.evaluate(node=>node.style.filter='none');
   const bounds=await frame.boundingBox(),clip={x:bounds.x,y:bounds.y,width:2,height:2};
   const corner=await page.screenshot({clip,encoding:'base64'});
   await element.evaluate(node=>node.style.visibility='hidden');
   const backdrop=await page.screenshot({clip,encoding:'base64'});
   await element.evaluate(node=>node.style.visibility='');
   const pixels=await page.evaluate(images=>Promise.all(images.map(source=>new Promise(resolve=>{
    const image=new Image();image.onload=()=>{const canvas=document.createElement('canvas');canvas.width=canvas.height=2;const context=canvas.getContext('2d');context.drawImage(image,0,0);resolve(Array.from(context.getImageData(0,0,2,2).data));};image.src='data:image/png;base64,'+source;
   }))),[corner,backdrop]);
   assert.deepEqual(pixels[0],pixels[1],'Browser painted an opaque background outside the editor corners');
   await frame.evaluate(node=>node.style.filter='');
   await frame.screenshot({path:join(shots,`${theme}-${scheme}.png`)});
   assert.deepEqual(failures,[]);report.push({theme,scheme,ok:true});console.log(theme,scheme,'window chrome passed');
  }finally{await context.close();}
 }
}finally{
 await writeFile(join(shots,'result.json'),JSON.stringify(report,null,2));await browser?.close();
 if(service.exitCode===null){const end=once(service,'exit');service.kill('SIGINT');await end;}
}
