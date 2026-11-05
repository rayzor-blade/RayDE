import {serve} from './channel-agent.mjs';
import {Frames,frame} from './preview-frames.mjs';

export const start = descriptor => serve(descriptor, {
  open({deliver,closed}) {
    if(parent===globalThis)throw Error('Open this app in its editor preview.');
    const origin=new URL(document.referrer).origin,pending=new Map();
    let ended=false;
    const receive=event=>{
      if(event.source!==parent||event.origin!==origin||event.data?.type!=='rayde-preview-files-reply')return;
      const value=event.data.reply,waiting=pending.get(value?.id);if(!waiting)return;
      clearTimeout(waiting);pending.delete(value.id);
      const bytes=frame(JSON.stringify(value));for(let at=0;at<bytes.length;at+=16384)deliver(bytes.subarray(at,at+16384));
    };
    addEventListener('message',receive);
    const requests=new Frames(text=>{
      const request=JSON.parse(text);
      if(ended||pending.size>=32)throw Error('The preview filesystem queue is full.');
      pending.set(request.id,setTimeout(()=>{pending.delete(request.id);const bytes=frame(JSON.stringify({id:request.id,ok:false,message:'The workspace did not answer the preview.'}));for(let at=0;at<bytes.length;at+=16384)deliver(bytes.subarray(at,at+16384));},15000));
      parent.postMessage({type:'rayde-preview-files',request},origin);
    });
    return {
      send(bytes){try{requests.push(bytes);}catch(error){closed(error.message);}},
      close(){ended=true;removeEventListener('message',receive);for(const timer of pending.values())clearTimeout(timer);pending.clear();}
    };
  }
});
