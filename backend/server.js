const express = require('express');
const cors = require('cors');
const http = require('http');
const fs = require('fs');
const path = require('path');

const apiRouter = require('./routes/api');
const { initDb, ensureDefaultAdmin, run, get, all } = require('./db/database');
const { initWebSocketServer, sendToUser } = require('./ws_handler');

const app = express();

app.use(cors());
app.use(express.json({ limit: '25mb' }));

const uploadsDir = path.join(__dirname, 'uploads');
try {
  if (!fs.existsSync(uploadsDir)) fs.mkdirSync(uploadsDir, { recursive: true });
} catch (_) {}
app.use('/uploads', express.static(uploadsDir));

const downloadPath = process.env.APK_FILE_PATH
  ? path.resolve(process.env.APK_FILE_PATH)
  : null;
const windowsPath = process.env.WINDOWS_FILE_PATH
  ? path.resolve(process.env.WINDOWS_FILE_PATH)
  : null;
const windowsExePath = process.env.WINDOWS_EXE_FILE_PATH
  ? path.resolve(process.env.WINDOWS_EXE_FILE_PATH)
  : path.join(__dirname, 'fenghuomixin-windows-setup.exe');

app.get('/', (req, res) => {
  res.setHeader('Cache-Control', 'no-store, no-transform');
  const apkHref = '/download.apk';
  const hasApk = downloadPath ? fs.existsSync(downloadPath) : false;
  const stat = hasApk ? fs.statSync(downloadPath) : null;
  const sizeMb = stat ? (stat.size / 1024 / 1024).toFixed(1) : null;
  const mtime = stat ? stat.mtime.toISOString().replace('T', ' ').slice(0, 19) : null;
  const windowsExeHref = '/download.windows.exe';
  const hasWindowsExe = windowsExePath ? fs.existsSync(windowsExePath) : false;
  const wExeStat = hasWindowsExe ? fs.statSync(windowsExePath) : null;
  const wExeSizeMb = wExeStat ? (wExeStat.size / 1024 / 1024).toFixed(1) : null;
  const wExeMtime = wExeStat ? wExeStat.mtime.toISOString().replace('T', ' ').slice(0, 19) : null;

  const windowsMsixHref = '/download.windows.msix';
  const hasWindowsMsix = windowsPath ? fs.existsSync(windowsPath) : false;
  const wMsixStat = hasWindowsMsix ? fs.statSync(windowsPath) : null;
  const wMsixSizeMb = wMsixStat ? (wMsixStat.size / 1024 / 1024).toFixed(1) : null;
  const wMsixMtime = wMsixStat ? wMsixStat.mtime.toISOString().replace('T', ' ').slice(0, 19) : null;
  const proto = (req.headers['x-forwarded-proto'] || req.protocol)
    .toString()
    .split(',')[0]
    .trim();
  const host = req.get('host');
  const pageUrl = `${proto}://${host}/`;
  const publicDownloadUrl = `${proto}://${host}${apkHref}`;
  const publicWindowsExeDownloadUrl = `${proto}://${host}${windowsExeHref}`;
  const publicWindowsMsixDownloadUrl = `${proto}://${host}${windowsMsixHref}`;
  const iosUrl = (process.env.IOS_DOWNLOAD_URL || '').toString().trim() || null;
  const qrUrl = `https://api.qrserver.com/v1/create-qr-code/?size=240x240&data=${encodeURIComponent(
    pageUrl
  )}`;
  res.status(200).type('html').send(`<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>烽火密信</title>
    <style>
      * { box-sizing: border-box; }
    </style>
  </head>
  <body style="margin:0; background:#0b1220; color:#e6e8ee; font-family: -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif;">
    <div style="max-width: 520px; margin: 0 auto; padding: 28px 16px 46px; text-align:center;">
      <div style="font-size: 28px; font-weight: 900; letter-spacing: 2px;">烽火密信</div>
      <div style="color:#a7b0c3; margin-top: 8px; line-height: 1.6;">专注安全沟通与隐私保护，支持即时消息与语音通话。</div>
      <div style="color:#8892a8; font-size: 13px; margin-top: 10px;">${new Date()
        .toISOString()
        .replace('T', ' ')
        .slice(0, 19)}</div>

      <div style="margin-top: 16px; background:#121a2b; border: 1px solid rgba(255,255,255,.08); border-radius: 16px; padding: 18px; overflow:hidden;">
        <div style="font-size: 16px; font-weight: 800; margin-bottom: 12px;">下载</div>
        <div style="display:flex; flex-direction: column; gap: 10px; align-items: stretch;">
          ${
            hasApk
              ? `<a href="${apkHref}" style="display:inline-flex; align-items:center; justify-content:center; padding: 12px 18px; background:#C62828; color:#fff; text-decoration:none; border-radius: 12px; font-weight: 800; width: 100%; max-width: 100%;">安卓下载</a>`
              : `<div style="display:inline-flex; align-items:center; justify-content:center; padding: 12px 18px; background:#2a2f3a; color:#9aa3b6; border-radius: 12px; font-weight: 800; width: 100%; max-width: 100%;">安卓包未上传</div>`
          }
          ${
            hasWindowsExe
              ? `<a href="${windowsExeHref}" style="display:inline-flex; align-items:center; justify-content:center; padding: 12px 18px; background:#1d2a45; color:#e6e8ee; text-decoration:none; border-radius: 12px; font-weight: 800; width: 100%; max-width: 100%;">Windows 安装包下载（EXE）</a>`
              : `<div style="display:inline-flex; align-items:center; justify-content:center; padding: 12px 18px; background:#2a2f3a; color:#9aa3b6; border-radius: 12px; font-weight: 800; width: 100%; max-width: 100%;">Windows 安装包未上传</div>`
          }
          ${
            hasWindowsMsix
              ? `<a href="${windowsMsixHref}" style="display:inline-flex; align-items:center; justify-content:center; padding: 12px 18px; background:#172238; color:#c9d1e3; text-decoration:none; border-radius: 12px; font-weight: 800; width: 100%; max-width: 100%;">Windows 下载（MSIX，可能提示证书）</a>`
              : ''
          }
          ${
            iosUrl
              ? `<a href="${iosUrl}" style="display:inline-flex; align-items:center; justify-content:center; padding: 12px 18px; background:#1d2a45; color:#e6e8ee; text-decoration:none; border-radius: 12px; font-weight: 800; width: 100%; max-width: 100%;">苹果下载</a>`
              : `<div style="display:inline-flex; align-items:center; justify-content:center; padding: 12px 18px; background:#2a2f3a; color:#9aa3b6; border-radius: 12px; font-weight: 800; width: 100%; max-width: 100%;">苹果暂未开放</div>`
          }
        </div>

        <div style="margin-top: 14px; color:#a7b0c3; font-size: 13px; line-height: 1.7; text-align:left;">
          <div>下载页：<span style="word-break: break-all; color:#d2d6e2;">${pageUrl}</span></div>
          <div>安卓直链：<span style="word-break: break-all; color:#d2d6e2;">${publicDownloadUrl}</span></div>
          <div>Windows 直链（EXE）：<span style="word-break: break-all; color:#d2d6e2;">${publicWindowsExeDownloadUrl}</span></div>
          ${hasWindowsMsix ? `<div>Windows 直链（MSIX）：<span style="word-break: break-all; color:#d2d6e2;">${publicWindowsMsixDownloadUrl}</span></div>` : ''}
          ${mtime ? `<div>安卓包更新时间：${mtime}${sizeMb ? `（${sizeMb} MB）` : ''}</div>` : ''}
          ${wExeMtime ? `<div>Windows 安装包更新时间：${wExeMtime}${wExeSizeMb ? `（${wExeSizeMb} MB）` : ''}</div>` : ''}
          ${wMsixMtime ? `<div>Windows MSIX 更新时间：${wMsixMtime}${wMsixSizeMb ? `（${wMsixSizeMb} MB）` : ''}</div>` : ''}
        </div>

        <div style="margin-top: 12px; color:#8892a8; font-size: 13px; line-height: 1.7; text-align:left;">
          <div>安装提示：</div>
          <div>1）安卓下载后若提示“禁止安装未知来源应用”，请在系统设置里允许</div>
          <div>2）Windows 安装包如提示“未知发布者/更多信息”，可选择“仍要运行”继续安装</div>
          <div>2）苹果如需下载，请后续提供 App Store/TestFlight 链接（设置 IOS_DOWNLOAD_URL）</div>
        </div>

        <div style="margin-top: 16px; text-align:center;">
          <div style="font-size: 13px; color:#a7b0c3; margin-bottom: 10px;">扫码打开下载页</div>
          <div style="display:inline-block; background:#ffffff; padding: 10px; border-radius: 14px;">
            <img src="${qrUrl}" alt="QR" width="240" height="240" style="display:block;" />
          </div>
        </div>
      </div>
    </div>
  </body>
</html>`);
});

app.get('/download.apk', (req, res) => {
  if (!downloadPath) {
    res.status(404).json({ message: 'APK_FILE_PATH not set' });
    return;
  }
  if (!fs.existsSync(downloadPath)) {
    res.status(404).json({ message: 'APK not found' });
    return;
  }
  const filename = 'fenghuomixin.apk';
  const stat = fs.statSync(downloadPath);
  const size = Number(stat.size || 0);
  const range = (req.headers.range || '').toString().trim();
  const ua = (req.headers['user-agent'] || '').toString().slice(0, 180);
  const ip =
    (req.headers['cf-connecting-ip'] || req.headers['x-real-ip'] || req.ip || '')
      .toString()
      .split(',')[0]
      .trim();

  const startedAt = Date.now();
  process.stdout.write(
    `download.apk start ip=${ip} range="${range}" ua="${ua}"\n`
  );
  res.on('finish', () => {
    process.stdout.write(
      `download.apk finish ip=${ip} status=${res.statusCode} ms=${Date.now() - startedAt}\n`
    );
  });
  res.on('close', () => {
    process.stdout.write(
      `download.apk close ip=${ip} status=${res.statusCode} ms=${Date.now() - startedAt}\n`
    );
  });

  res.setHeader('Content-Type', 'application/vnd.android.package-archive');
  res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
  res.setHeader('Cache-Control', 'no-store, no-transform');
  res.setHeader('Accept-Ranges', 'bytes');
  res.setHeader('X-Content-Type-Options', 'nosniff');

  if (range && range.startsWith('bytes=')) {
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!m) {
      res.status(416).end();
      return;
    }
    const start = m[1] ? Math.max(0, Number(m[1])) : 0;
    const end = m[2] ? Math.min(size - 1, Number(m[2])) : size - 1;
    if (!Number.isFinite(start) || !Number.isFinite(end) || start > end || start >= size) {
      res.status(416).end();
      return;
    }
    const chunkSize = end - start + 1;
    res.status(206);
    res.setHeader('Content-Range', `bytes ${start}-${end}/${size}`);
    res.setHeader('Content-Length', String(chunkSize));
    fs.createReadStream(downloadPath, { start, end }).pipe(res);
    return;
  }

  res.status(200);
  res.setHeader('Content-Length', String(size));
  fs.createReadStream(downloadPath).pipe(res);
});

app.get('/download.windows.msix', (req, res) => {
  if (!windowsPath) {
    res.status(404).json({ message: 'WINDOWS_FILE_PATH not set' });
    return;
  }
  if (!fs.existsSync(windowsPath)) {
    res.status(404).json({ message: 'Windows package not found' });
    return;
  }
  const filename = 'fenghuomixin-windows.msix';
  const stat = fs.statSync(windowsPath);
  const size = Number(stat.size || 0);
  const range = (req.headers.range || '').toString().trim();

  res.setHeader('Content-Type', 'application/msix');
  res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
  res.setHeader('Cache-Control', 'no-store, no-transform');
  res.setHeader('Accept-Ranges', 'bytes');

  if (range && range.startsWith('bytes=')) {
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!m) {
      res.status(416).end();
      return;
    }
    const start = m[1] ? Math.max(0, Number(m[1])) : 0;
    const end = m[2] ? Math.min(size - 1, Number(m[2])) : size - 1;
    if (!Number.isFinite(start) || !Number.isFinite(end) || start > end || start >= size) {
      res.status(416).end();
      return;
    }
    const chunkSize = end - start + 1;
    res.status(206);
    res.setHeader('Content-Range', `bytes ${start}-${end}/${size}`);
    res.setHeader('Content-Length', String(chunkSize));
    fs.createReadStream(windowsPath, { start, end }).pipe(res);
    return;
  }

  res.status(200);
  res.setHeader('Content-Length', String(size));
  fs.createReadStream(windowsPath).pipe(res);
});

app.get('/download.windows.exe', (req, res) => {
  if (!windowsExePath) {
    res.status(404).json({ message: 'WINDOWS_EXE_FILE_PATH not set' });
    return;
  }
  if (!fs.existsSync(windowsExePath)) {
    res.status(404).json({ message: 'Windows installer not found' });
    return;
  }
  const filename = 'fenghuomixin-windows-setup.exe';
  const stat = fs.statSync(windowsExePath);
  const size = Number(stat.size || 0);
  const range = (req.headers.range || '').toString().trim();

  res.setHeader('Content-Type', 'application/octet-stream');
  res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
  res.setHeader('Cache-Control', 'no-store, no-transform');
  res.setHeader('Accept-Ranges', 'bytes');
  res.setHeader('X-Content-Type-Options', 'nosniff');

  if (range && range.startsWith('bytes=')) {
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!m) {
      res.status(416).end();
      return;
    }
    const start = m[1] ? Math.max(0, Number(m[1])) : 0;
    const end = m[2] ? Math.min(size - 1, Number(m[2])) : size - 1;
    if (!Number.isFinite(start) || !Number.isFinite(end) || start > end || start >= size) {
      res.status(416).end();
      return;
    }
    const chunkSize = end - start + 1;
    res.status(206);
    res.setHeader('Content-Range', `bytes ${start}-${end}/${size}`);
    res.setHeader('Content-Length', String(chunkSize));
    fs.createReadStream(windowsExePath, { start, end }).pipe(res);
    return;
  }

  res.status(200);
  res.setHeader('Content-Length', String(size));
  fs.createReadStream(windowsExePath).pipe(res);
});

function mountAdminSpaWithQuotaOverlay(basePath, dirPath) {
  const indexPath = path.join(dirPath, 'index.html');
  if (!fs.existsSync(indexPath)) return false;

  const overlayScript = `
  <script>(function(){
    var KEY="__fh_quota_overlay__";
    if(window[KEY]) return; window[KEY]=true;
    function looksLikeJwt(v){ if(!v||typeof v!=="string") return false; var p=v.split("."); return p.length===3 && v.length>40; }
    function findTokenInStorage(st){ try{ if(!st) return ""; for(var i=0;i<st.length;i++){ var k=st.key(i); var v=st.getItem(k); if(looksLikeJwt(v)) return v; } }catch(e){} return ""; }
    function getToken(){ return findTokenInStorage(window.localStorage)||findTokenInStorage(window.sessionStorage)||""; }
    async function api(path, opts){
      opts=opts||{}; opts.headers=opts.headers||{};
      var t=getToken();
      if(t) opts.headers["Authorization"]="Bearer "+t;
      if(!opts.headers["Content-Type"] && opts.method && opts.method!=="GET") opts.headers["Content-Type"]="application/json";
      if(!opts.cache) opts.cache="no-store";
      var res=await fetch(path, opts);
      var data=null; try{ data=await res.json(); }catch(e){}
      if(!res.ok){ var msg=(data&&data.message)?data.message:("HTTP "+res.status); throw new Error(msg); }
      return data;
    }
    function isSuperUser(me){
      try{
        var u=me&&me.user?me.user:null;
        if(!u) return false;
        if(String(u.username||"")==="admin") return true;
        return String(u.role||"")==="super";
      }catch(e){ return false; }
    }
    function el(tag, attrs){
      var n=document.createElement(tag);
      if(attrs){ for(var k in attrs){ if(k==="text") n.textContent=attrs[k]; else if(k==="html") n.innerHTML=attrs[k]; else n.setAttribute(k, attrs[k]); } }
      return n;
    }
    function css(n, styles){
      for(var k in styles){
        var v=styles[k];
        try{
          var prop=k.replace(/[A-Z]/g,function(m){return "-"+m.toLowerCase();});
          n.style.setProperty(prop, v, "important");
        }catch(e){
          try{ n.style[k]=v; }catch(e2){}
        }
      }
    }
    function safeInt(v){ var n=Number(v); if(!Number.isFinite(n)) return null; return Math.trunc(n); }
    function remaining(limit, used){ if(limit==null||limit<0) return -1; var r=limit-(used||0); return r<0?0:r; }
    function fmtLimit(limit){ if(limit==null) return "-"; if(limit<0) return "无限制"; return String(limit); }
    function fmtRemain(rem){ if(rem<0) return "无限制"; return String(rem); }

    var root=el("div",{id:"fhQuotaOverlayRoot"});
    css(root,{position:"fixed",right:"14px",bottom:"14px",zIndex:"2147483647",fontFamily:"-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif"});
    var btn=el("button",{type:"button",text:"额度管理"});
    css(btn,{border:"1px solid rgba(0,0,0,.14)",background:"#ffffff",color:"#111827",borderRadius:"10px",padding:"10px 12px",cursor:"pointer",fontWeight:"900",boxShadow:"0 12px 30px rgba(0,0,0,.35)"});
    var panel=el("div");
    css(panel,{display:"none",marginTop:"10px",width:"720px",maxWidth:"calc(100vw - 28px)",maxHeight:"70vh",overflow:"auto",background:"#ffffff",color:"#111827",border:"1px solid rgba(0,0,0,.14)",borderRadius:"14px",padding:"12px",boxShadow:"0 16px 40px rgba(0,0,0,.45)"});
    var head=el("div");
    css(head,{display:"flex",gap:"10px",alignItems:"center"});
    var title=el("div",{text:"子管理员新建账号额度"});
    css(title,{fontWeight:"900",fontSize:"14px"});
    var hint=el("div",{text:""});
    css(hint,{marginLeft:"auto",color:"rgba(17,24,39,.75)",fontSize:"12px"});
    var close=el("button",{type:"button",text:"关闭"});
    css(close,{border:"1px solid rgba(0,0,0,.14)",background:"#f3f4f6",color:"#111827",borderRadius:"10px",padding:"8px 10px",cursor:"pointer",fontWeight:"900"});
    head.appendChild(title); head.appendChild(hint); head.appendChild(close);
    var table=el("table");
    css(table,{width:"100%",borderCollapse:"collapse",marginTop:"10px",fontSize:"12px"});
    panel.appendChild(head); panel.appendChild(table);
    root.appendChild(btn); root.appendChild(panel);

    function render(rows){
      table.innerHTML="";
      var thead=el("thead");
      thead.innerHTML="<tr>"+
        "<th style='text-align:left;padding:8px;border-bottom:1px solid #e5e7eb;color:#111827 !important'>ID</th>"+
        "<th style='text-align:left;padding:8px;border-bottom:1px solid #e5e7eb;color:#111827 !important'>用户名</th>"+
        "<th style='text-align:left;padding:8px;border-bottom:1px solid #e5e7eb;color:#111827 !important'>角色</th>"+
        "<th style='text-align:left;padding:8px;border-bottom:1px solid #e5e7eb;color:#111827 !important'>额度</th>"+
        "<th style='text-align:left;padding:8px;border-bottom:1px solid #e5e7eb;color:#111827 !important'>已用</th>"+
        "<th style='text-align:left;padding:8px;border-bottom:1px solid #e5e7eb;color:#111827 !important'>剩余</th>"+
        "<th style='text-align:left;padding:8px;border-bottom:1px solid #e5e7eb;color:#111827 !important'>调整</th>"+
      "</tr>";
      table.appendChild(thead);
      var tbody=el("tbody");
      var list=Array.isArray(rows)?rows:[];
      for(var i=0;i<list.length;i++){
        var a=list[i]||{};
        var id=safeInt(a.id);
        var username=String(a.username||"");
        var role=String(a.role||"");
        var status=String(a.status||"");
        var limit=safeInt(a.create_account_limit);
        var used=safeInt(a.created_account_used)||0;
        var rem=remaining(limit, used);
        var tr=el("tr");
        tr.innerHTML=
          "<td style='padding:8px;border-bottom:1px solid #f1f5f9;color:#111827 !important'>"+(id||"")+"</td>"+
          "<td style='padding:8px;border-bottom:1px solid #f1f5f9;color:#111827 !important'>"+username.replace(/</g,"&lt;")+"</td>"+
          "<td style='padding:8px;border-bottom:1px solid #f1f5f9;color:#111827 !important'>"+(username==="admin"?"super":(role||"-"))+"</td>"+
          "<td style='padding:8px;border-bottom:1px solid #f1f5f9;color:#111827 !important'>"+fmtLimit(limit)+"</td>"+
          "<td style='padding:8px;border-bottom:1px solid #f1f5f9;color:#111827 !important'>"+String(used)+"</td>"+
          "<td style='padding:8px;border-bottom:1px solid #f1f5f9;color:#111827 !important'>"+fmtRemain(rem)+"</td>";
        var td=el("td");
        css(td,{padding:"8px",borderBottom:"1px solid #f1f5f9",color:"#111827"});
        if(!id || username==="admin" || role==="super"){
          td.textContent="-";
        }else{
          var wrap=el("div");
          css(wrap,{display:"flex",gap:"6px",alignItems:"center",flexWrap:"wrap"});
          const minus=el("button",{type:"button",text:"-"});
          const plus=el("button",{type:"button",text:"+"});
          const inp=el("input",{type:"number"});
          inp.value=String(limit==null?-1:limit);
          inp.min="-1"; inp.step="1";
          css(inp,{width:"90px",border:"1px solid rgba(0,0,0,.14)",background:"#ffffff",color:"#111827",borderRadius:"10px",padding:"8px 10px",outline:"none"});
          function btnStyle(b){ css(b,{border:"1px solid rgba(0,0,0,.14)",background:"#f3f4f6",color:"#111827",borderRadius:"10px",padding:"8px 10px",cursor:"pointer",fontWeight:"900"}); }
          btnStyle(minus); btnStyle(plus);
          const save=el("button",{type:"button",text:"保存"});
          css(save,{border:"1px solid rgba(0,0,0,.14)",background:"#2563eb",color:"#ffffff",borderRadius:"10px",padding:"8px 10px",cursor:"pointer",fontWeight:"900"});
          function clamp(v){ var n=safeInt(v); if(n==null) return null; if(n<-1) return -1; return n; }
          minus.onclick=function(){ var cur=clamp(inp.value); if(cur==null) return; if(cur===-1) return; inp.value=String(cur-1<-1?-1:cur-1); };
          plus.onclick=function(){ var cur=clamp(inp.value); if(cur==null) return; inp.value=String(cur===-1?0:cur+1); };
          save.onclick=(function(adminId){
            return async function(){
              var next=clamp(inp.value);
              if(next==null){ alert("请输入整数（-1 表示无限制）"); return; }
              save.disabled=true;
              try{
                await api("/api/admin/admins/"+adminId+"/permissions",{method:"PUT",body:JSON.stringify({createAccountLimit: next})});
                await load();
              }catch(e){ alert(e.message||"保存失败"); }
              finally{ save.disabled=false; }
            };
          })(id);
          wrap.appendChild(minus); wrap.appendChild(inp); wrap.appendChild(plus); wrap.appendChild(save);
          td.appendChild(wrap);
        }
        tr.appendChild(td);
        tbody.appendChild(tr);
      }
      table.appendChild(tbody);
    }

    async function load(){
      hint.textContent="加载中…";
      try{
        var r=await api("/api/admin/admins?ts="+Date.now(),{method:"GET"});
        render(r.admins||[]);
        hint.textContent="已加载";
      }catch(e){
        hint.textContent=e.message||"加载失败";
        render([]);
      }
    }

    btn.onclick=async function(){
      if(panel.style.display==="none"){
        panel.style.display="block";
        await load();
      }else{
        panel.style.display="none";
      }
    };
    close.onclick=function(){ panel.style.display="none"; };

    (async function(){
      try{
        var me=await api("/api/admin/me?ts="+Date.now(),{method:"GET"});
        if(!isSuperUser(me)) return;
        document.body.appendChild(root);
      }catch(e){}
    })();
  })();</script>`;

  let cached = null;
  let cachedMtimeMs = 0;
  function getHtml() {
    try {
      const st = fs.statSync(indexPath);
      const m = Number(st.mtimeMs || 0);
      if (cached && cachedMtimeMs === m) return cached;
      const raw = fs.readFileSync(indexPath, 'utf8');
      const injected = raw.includes('__fh_quota_overlay__')
        ? raw
        : raw.replace(/<\/body\s*>/i, `${overlayScript}</body>`);
      cached = injected === raw ? `${raw}${overlayScript}` : injected;
      cachedMtimeMs = m;
      return cached;
    } catch (_) {
      return null;
    }
  }

  app.use(
    basePath,
    express.static(dirPath, {
      etag: true,
      maxAge: 0,
      setHeaders(res) {
        res.setHeader('Cache-Control', 'no-store, no-transform');
        res.setHeader('X-Content-Type-Options', 'nosniff');
        res.setHeader('X-FH-Admin-Overlay', '1');
      },
    })
  );

  function sendIndex(req, res) {
    const html = getHtml();
    if (!html) return res.status(404).end();
    res.status(200);
    res.setHeader('Content-Type', 'text/html; charset=UTF-8');
    res.setHeader('Cache-Control', 'no-store, no-transform');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-FH-Admin-Overlay', '1');
    res.end(html);
  }

  app.get(basePath, sendIndex);
  app.get(`${basePath}/*`, sendIndex);
  return true;
}

mountAdminSpaWithQuotaOverlay('/admin', path.join(__dirname, 'admin'));

app.use(apiRouter);

const host = '0.0.0.0';
const port = 3000;
const JWT_SECRET = process.env.JWT_SECRET || 'fenghuo_dev_secret';

function toConversationId(a, b) {
  const x = Number(a);
  const y = Number(b);
  if (Number.isNaN(x) || Number.isNaN(y)) return null;
  const min = Math.min(x, y);
  const max = Math.max(x, y);
  return `${min}_${max}`;
}

function messageTypeFromContent(content) {
  const v = (content || '').toString().trim();
  if (v === '[图片]' || v === '[拍照]') return 'image';
  const lower = v.toLowerCase();
  if (
    lower.endsWith('.png') ||
    lower.endsWith('.jpg') ||
    lower.endsWith('.jpeg') ||
    lower.endsWith('.gif') ||
    lower.endsWith('.webp') ||
    lower.endsWith('.heic')
  ) {
    return 'image';
  }
  return 'text';
}

async function isEitherBlocked(fromId, toId) {
  try {
    const a = Number(fromId);
    const b = Number(toId);
    if (!a || !b) return false;
    const ab = await get(
      'SELECT id FROM user_blocks WHERE user_id = ? AND blocked_user_id = ? LIMIT 1;',
      [a, b]
    );
    if (ab) return true;
    const ba = await get(
      'SELECT id FROM user_blocks WHERE user_id = ? AND blocked_user_id = ? LIMIT 1;',
      [b, a]
    );
    return !!ba;
  } catch (_) {
    return false;
  }
}

let _scheduledWorkerTimer = null;

function startScheduledMessageWorker() {
  if (_scheduledWorkerTimer) return;
  _scheduledWorkerTimer = setInterval(() => {
    (async () => {
      const now = Date.now();
      const tasks = await all(
        `
        SELECT id, from_id AS fromId, to_id AS toId, conversation_id AS conversationId, content
        FROM scheduled_messages
        WHERE status = 'pending' AND send_at_ms <= ?
        ORDER BY send_at_ms ASC, id ASC
        LIMIT 20;
        `,
        [now]
      );
      if (!tasks || !tasks.length) return;

      for (const t of tasks) {
        const id = Number(t.id);
        const fromId = Number(t.fromId);
        const toId = Number(t.toId);
        const conversationId = String(t.conversationId || '');
        const content = (t.content ?? '').toString();
        if (!id || !fromId || !toId || !conversationId) continue;

        const claimed = await run(
          "UPDATE scheduled_messages SET status = 'sending' WHERE id = ? AND status = 'pending';",
          [id]
        );
        if (!claimed || Number(claimed.changes) !== 1) continue;

        try {
          const cid = toConversationId(fromId, toId);
          if (!cid || cid !== conversationId) {
            throw new Error('conversation_id_invalid');
          }
          if (await isEitherBlocked(fromId, toId)) {
            throw new Error('blocked');
          }

          const result = await run(
            'INSERT INTO messages (conversation_id, sender_id, content) VALUES (?, ?, ?);',
            [conversationId, fromId, content]
          );
          const row = await get('SELECT * FROM messages WHERE id = ?;', [result.lastID]);

          try {
            const sender = await get(
              'SELECT id, username, nickname, avatar FROM accounts WHERE id = ? LIMIT 1;',
              [fromId]
            );
            const pushContent = content.trim().startsWith('data:image/') ? '[图片]' : content;
            sendToUser(toId, {
              type: 'new_message',
              fromId,
              toId,
              conversationId,
              messageId: row ? row.id : result.lastID,
              content: pushContent,
              timestamp: row ? row.timestamp : null,
              fromUsername: sender ? sender.username : null,
              fromNickname: sender ? sender.nickname : null,
              fromAvatar: sender ? sender.avatar : null,
            });
          } catch (_) {}

          try {
            const messageType = messageTypeFromContent(content);
            await run(
              'INSERT INTO message_audit (sender_id, receiver_id, message_type) VALUES (?, ?, ?);',
              [fromId, toId, messageType]
            );
          } catch (_) {}

          await run(
            "UPDATE scheduled_messages SET status = 'sent', sent_at_ms = ?, error = NULL WHERE id = ?;",
            [Date.now(), id]
          );
        } catch (e) {
          const msg = String((e && e.message) || e || 'failed').slice(0, 300);
          try {
            await run(
              "UPDATE scheduled_messages SET status = 'failed', sent_at_ms = ?, error = ? WHERE id = ?;",
              [Date.now(), msg, id]
            );
          } catch (_) {}
        }
      }
    })().catch(() => {});
  }, 3000);
}

async function bootstrap() {
  await initDb();
  await ensureDefaultAdmin();

  const server = http.createServer(app);
  initWebSocketServer(server, { jwtSecret: JWT_SECRET, path: '/ws' });

  server.listen(port, host, () => {
    process.stdout.write(`backend listening on http://${host}:${port}\n`);
  });

  startScheduledMessageWorker();
}

bootstrap().catch((e) => {
  process.stderr.write(`${e && e.stack ? e.stack : e}\n`);
  process.exit(1);
});
