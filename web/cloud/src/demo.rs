use super::*;
use serde::{Deserialize,Serialize};
use std::{rc::Rc,time::Duration};

const COOKIE:&str="rayde_demo";
const LIFETIME:u64=15*60*1000;
const IDLE:u64=5*60*1000;

fn settings(env:&Env)->AppResult<(String,String,usize)> {
    let origin=config(env,"DEMO_ORIGIN").ok_or_else(||bad(404,"Demo admission is not enabled."))?;
    let url=Url::parse(&origin).map_err(|_|bad(503,"Invalid demo configuration."))?;
    if url.origin().ascii_serialization()!=origin || (url.scheme()!="https" && config(env,"LOCAL_DEV").as_deref()!=Some("1"))
        || preview_origin(env).as_deref()==Some(origin.as_str()) || config(env,"ASSETS_ORIGIN").as_deref()==Some(origin.as_str()) {
        return Err(bad(503,"Invalid demo origin."));
    }
    let release=config(env,"DEMO_RELEASE").filter(|value|opaque(value)).ok_or_else(||bad(503,"The demo source release is not configured."))?;
    if config(env,"DEMO_TOOLCHAIN").filter(|value|opaque(value)).is_none() {return Err(bad(503,"The demo toolchain image is not configured."));}
    let maximum=config(env,"DEMO_MAX_SESSIONS").unwrap_or_else(||"1".into()).parse::<usize>().ok().filter(|value|(1..=8).contains(value))
        .ok_or_else(||bad(503,"Invalid demo capacity."))?;
    Ok((origin,release,maximum))
}

fn cookie(raw:&str,secure:bool,age:u64)->String {
    format!("{COOKIE}={raw}; Path=/api/demo; HttpOnly; SameSite=Strict; Max-Age={age}{}",if secure{"; Secure"}else{""})
}

pub(crate) async fn route(req:Request,env:Env)->AppResult<Response> {
    let (origin,_,_)=settings(&env)?;
    let url=req.url()?;
    if url.origin().ascii_serialization()!=origin {return Err(bad(404,"Not found."));}
    let action=url.path().strip_prefix("/api/demo/").ok_or_else(||bad(404,"Not found."))?;
    let socket=action=="socket";
    let method=if socket || action=="status" {Method::Get}else{Method::Post};
    if req.method()!=method || !["open","status","retry","end","socket"].contains(&action) {return Err(bad(405,"Unsupported demo operation."));}
    let supplied=req.headers().get("Origin")?;
    if supplied.as_ref().is_some_and(|value|value!=&origin) || (method==Method::Post || socket) && supplied.as_deref()!=Some(&origin)
        || req.headers().get("Sec-Fetch-Site")?.as_deref()==Some("cross-site") {return Err(bad(403,"This demo request is not allowed."));}
    let previous=cookie_value(&req,COOKIE);
    if previous.as_ref().is_some_and(|value|!opaque(value)) {return Err(bad(401,"The demo lease is invalid."));}
    if previous.is_none() && action!="open" {return Err(bad(401,"Start the demo session first."));}
    let raw=match &previous {Some(raw)=>raw.clone(),None=>random()?};
    let key=hash(&format!("demo-cookie:{raw}"));
    let ip=req.headers().get("CF-Connecting-IP")?.or_else(||(config(&env,"LOCAL_DEV").as_deref()==Some("1")).then(||"local".into()))
        .filter(|value|value.len()<=128 && !value.chars().any(char::is_whitespace)).ok_or_else(||bad(503,"Demo admission is unavailable."))?;
    let data=json!({"key":key,"new":previous.is_none(),"ip":hash(&format!("demo-ip:{ip}")),"origin":origin});
    if socket {
        if req.headers().get("Upgrade")?.is_none_or(|value|!value.eq_ignore_ascii_case("websocket")) {return Err(bad(400,"A demo WebSocket is required."));}
        let headers=Headers::new();headers.set("Upgrade","websocket")?;headers.set("X-RayDE-Demo",&data.to_string())?;
        return Ok(env.durable_object("DEMO_ADMISSIONS")?.get_by_name("landing")?.fetch_with_request(
            Request::new_with_init("https://demo/socket",RequestInit::new().with_headers(headers))?).await?);
    }
    let value=rpc(&env,"DEMO_ADMISSIONS","landing",action,&data).await?;
    let mut response=reply(&value,if value["status"]=="preparing" {202}else{200})?;
    if previous.is_none() || action=="end" {
        response.headers_mut().append("Set-Cookie",&cookie(if action=="end"{""}else{&raw},url.scheme()=="https",if action=="end"{0}else{LIFETIME/1000}))?;
    }
    Ok(response)
}

#[derive(Clone,Serialize,Deserialize)]
struct Lease {key:String,id:String,lease:String,release:String,expires:u64,idle:u64,phase:String,attempts:u8,retry:u64,cleanup:u64}
#[derive(Serialize,Deserialize)]
struct Rate {key:String,expires:u64,count:u8}
#[derive(Default,Serialize,Deserialize)]
struct Ledger {leases:Vec<Lease>,rates:Vec<Rate>}

impl Lease {
    fn owner(&self)->String {format!("demo:{}",self.id)}
    fn repository(&self)->Value {json!({"id":0,"fullName":"demo/pocket-studio","demo":{"release":self.release,"lease":self.lease,"expires":self.expires/1000}})}
    fn live(&self)->AppResult<()> {
        if self.phase!="active" || self.expires<=now() || self.idle<=now() {return Err(bad(410,"The demo session expired."));}
        Ok(())
    }
}

#[durable_object]
pub struct DemoAdmissions {state:State,env:Env,gate:Rc<futures_util::lock::Mutex<()>>}
impl DurableObject for DemoAdmissions {
    fn new(state:State,env:Env)->Self {Self{state,env,gate:Rc::new(futures_util::lock::Mutex::new(()))}}
    async fn fetch(&self,req:Request)->Result<Response> {finish(self.handle(req).await)}
    async fn alarm(&self)->Result<Response> {
        let _guard=self.gate.lock().await;
        let storage=self.state.storage();let mut ledger=storage.get::<Ledger>("ledger").await?.unwrap_or_default();
        let mut work=Vec::new();
        for lease in &mut ledger.leases {
            if lease.phase=="active" && (lease.expires<=now() || lease.idle<=now()) {lease.phase="closing".into();}
            if lease.phase=="closing" && lease.cleanup<=now() {lease.cleanup=now()+120_000;work.push(lease.clone());}
        }
        storage.put("ledger",&ledger).await?;schedule(&storage,&ledger).await?;
        for lease in work {self.cleanup(lease);}
        Response::empty()
    }
}
async fn schedule(storage:&Storage,ledger:&Ledger)->Result<()> {
    if let Some(next)=ledger.leases.iter().filter(|lease|lease.phase!="ended").map(|lease|if lease.phase=="active"{lease.idle.min(lease.expires)}else{lease.cleanup}).min() {
        storage.set_alarm(Duration::from_millis(next.saturating_sub(now()).max(1))).await?;
    } else {storage.delete_alarm().await?;}
    Ok(())
}
impl DemoAdmissions {
    async fn handle(&self,mut req:Request)->AppResult<Response> {
        let data:Value=if req.path()=="/socket" {serde_json::from_str(&req.headers().get("X-RayDE-Demo")?.unwrap_or_default()).map_err(|_|bad(403,"Invalid demo admission."))?}else{req.json().await?};
        let key=text(&data,"key")?;
        if key.len()!=43 {return Err(bad(403,"Invalid demo lease."));}
        let guard=self.gate.lock().await;
        let storage=self.state.storage();let mut ledger=storage.get::<Ledger>("ledger").await?.unwrap_or_default();
        let mut dirty=false;
        if req.path()=="/open" && data["new"]==true {
            let (_,release,maximum)=settings(&self.env)?;
            ledger.rates.retain(|rate|rate.expires>now());
            let ip=text(&data,"ip")?;
            if let Some(rate)=ledger.rates.iter_mut().find(|rate|rate.key==ip) {
                if rate.count>=3 {return Err(bad(429,"Please wait before starting another demo."));}rate.count+=1;
            } else {
                if ledger.rates.len()>=512 {return Err(bad(429,"Demo admission is busy. Try again shortly."));}
                ledger.rates.push(Rate{key:ip.into(),expires:now()+60_000,count:1});
            }
            ledger.leases.retain(|lease|lease.phase!="ended");
            storage.put("ledger",&ledger).await?;
            if ledger.leases.len()>=maximum {return Err(bad(429,"All demo sessions are in use. You can keep editing while you wait."));}
            let lease=hash(&format!("demo-lease:{key}"));
            let id=URL_SAFE_NO_PAD.encode(Sha256::digest(format!("demo:{release}:{lease}")));
            ledger.leases.push(Lease{key:key.into(),id,lease,release,expires:now()+LIFETIME,idle:now()+IDLE,phase:"active".into(),attempts:0,retry:0,cleanup:0});
            dirty=true;
        }
        let Some(index)=ledger.leases.iter().position(|lease|lease.key==key) else {
            if req.path()=="/end" {return Ok(reply(&json!({"status":"ended"}),200)?);}
            return Err(bad(410,"This demo lease is no longer available."));
        };
        if req.path()=="/end" {
            let lease=&mut ledger.leases[index];lease.phase="closing".into();lease.cleanup=now()+120_000;
            let work=lease.clone();storage.put("ledger",&ledger).await?;schedule(&storage,&ledger).await?;
            self.cleanup(work);return Ok(reply(&json!({"status":"closing"}),202)?);
        }
        ledger.leases[index].live()?;
        if req.path()=="/activity" {
            ledger.leases[index].idle=(now()+IDLE).min(ledger.leases[index].expires);
            storage.put("ledger",&ledger).await?;schedule(&storage,&ledger).await?;
            return Ok(reply(&json!({}),200)?);
        }
        let start=ledger.leases[index].attempts==0 || req.path()=="/retry";
        if start {
            let lease=&mut ledger.leases[index];
            if lease.attempts>=3 || lease.retry>now() {return Err(bad(429,"Wait before retrying the demo session."));}
            lease.attempts+=1;lease.retry=now()+5000;
            dirty=true;
        }
        let lease=ledger.leases[index].clone();
        if dirty {storage.put("ledger",&ledger).await?;schedule(&storage,&ledger).await?;}drop(guard);
        let owner=lease.owner();
        if req.path()=="/socket" {
            let headers=Headers::new();headers.set("Upgrade","websocket")?;
            headers.set("X-RayDE-Identity",&json!({"owner":owner,"sid":key,"expires":lease.expires,"origin":data["origin"],"access":null,"demoKey":key}).to_string())?;
            return Ok(self.env.durable_object("DEMO_WORKSPACES")?.get_by_name(&lease.id)?.fetch_with_request(
                Request::new_with_init("https://demo/socket",RequestInit::new().with_headers(headers))?).await?);
        }
        let record=match rpc(&self.env,"DEMO_WORKSPACES",&lease.id,if start{"open"}else{"state"},
            &json!({"id":lease.id,"owner":owner,"repository":lease.repository(),"access":null})).await {
            Ok(record)=>record,Err(error)=>json!({"status":"failed","message":error.message}),
        };
        Ok(reply(&json!({"id":lease.id,"release":lease.release,"expires":lease.expires,"idleUntil":lease.idle,
            "status":record["status"],"message":record["message"],"project":record["project"],"socket":"/api/demo/socket"}),200)?)
    }
    fn cleanup(&self,lease:Lease) {
        let env=self.env.clone();let storage=self.state.storage();let gate=self.gate.clone();
        self.state.wait_until(async move {
            let work=async {
                rpc(&env,"DEMO_WORKSPACES",&lease.id,"demo/end",&json!({"owner":lease.owner()})).await?;
                let base=config(&env,"RUNNER_URL").unwrap_or_else(||"https://runner.internal".into());
                let mut req=request(&format!("{}/workspaces/delete",base.trim_end_matches('/')),&json!({"id":lease.id,"owner":0,"demo":lease.repository()["demo"]}))?;
                req.headers_mut()?.set("Authorization",&format!("Bearer {}",config(&env,"RUNNER_SECRET").ok_or_else(||bad(503,"Demo cleanup is unavailable."))?))?;
                let response=if let Ok(binding)=env.service("RUNNER") {binding.fetch_request(req).await?}else{Fetch::Request(req).send().await?};
                if response.status_code()>=400 && response.status_code()!=404 {return Err(bad(503,"Demo cleanup is pending."));}
                rpc(&env,"DEMO_WORKSPACES",&lease.id,"demo/purge",&json!({"owner":lease.owner()})).await?;
                Ok::<(),Failure>(())
            };
            if workspace::deadline(work,90).await.is_ok_and(|result|result.is_ok()) {
                let _guard=gate.lock().await;
                if let Ok(Some(mut ledger))=storage.get::<Ledger>("ledger").await {
                    if let Some(current)=ledger.leases.iter_mut().find(|current|current.key==lease.key) {current.phase="ended".into();}
                    let _=storage.put("ledger",&ledger).await;let _=schedule(&storage,&ledger).await;
                }
            }
        });
    }
}
