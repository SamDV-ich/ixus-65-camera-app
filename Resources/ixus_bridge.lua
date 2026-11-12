-- Host-side adapter for the IXUS 65 profile; modes are validated by camera CHDK.
local M={}
local function json(v)
 if type(v)=='boolean' or type(v)=='number' then return tostring(v) end
 if v==nil then return 'null' end
 if type(v)=='string' then return '"'..v:gsub('[%z\1-\31\\"]',function(c) return string.format('\\u%04x',c:byte()) end)..'"' end
 local out={}; for k,x in pairs(v) do out[#out+1]=json(tostring(k))..':'..json(x) end
 return '{'..table.concat(out,',')..'}'
end
local function remote(code) return con:execwait(code,{timeout=60000}) end
local hold_backlight_off=false
local function state()
 -- An explicit keep-off policy also handles Canon buttons that wake the lamp.
 -- Reapply within the existing state request, not in the frame-transfer loop.
 local prefix=hold_backlight_off and 'set_backlight(0); ' or ''
 return remote(prefix..[[local p=require'propcase'; local c=require'capmode'; return {mode=c.get(),modeName=c.get_name(),flash=get_prop(p.FLASH_MODE),zoom=get_zoom(),focus=get_focus(),aflock=get_prop(p.AF_LOCK),focusRange=p.REAL_FOCUS_MODE and get_prop(p.REAL_FOCUS_MODE) or nil,record=get_mode(),battery=get_vbatt(),batteryMin=get_config_value(2101),batteryMax=get_config_value(2100)}]])
end
local verified_build
local connection_generation=0
local restore_display_needed=false
local function restore_display()
 if restore_display_needed and con:is_connected() then
  local ok=pcall(function() remote('set_backlight(1); sleep(200)') end)
  if ok then restore_display_needed=false; hold_backlight_off=false end
 end
end
function M.run(action,value,output,request_id)
 local ok,result=pcall(function()
  action=action or os.getenv('IXUS_ACTION') or 'status'
  -- Background reads and display commands must never reopen a lost session.
  if (action=='poll' or action=='frame' or action=='display') and not con:is_connected() then
   error('Соединение с камерой прервано. Нажмите «Подключить».')
  end
  if not con:is_connected() then
   local count=0; for _,d in ipairs(chdk.list_usb_devices()) do if d.product_id==0x30fe then count=count+1 end end
   if count==0 then error('IXUS_ABSENT: Камера не найдена. Включите CHDK и подключите USB.') end
   if count~=1 then error('Подключите ровно одну IXUS 65.') end
   cli:execute('connect -p=0x30fe')
   if con:is_connected() then connection_generation=connection_generation+1; hold_backlight_off=false end
  end
  if not con:is_connected() then error('Камера обнаружена, но сеанс недоступен. Закройте другие программы работы с камерой или переподключите USB.') end
  if not verified_build then
   local count=0; for _,d in ipairs(chdk.list_usb_devices()) do if d.product_id==0x30fe then count=count+1 end end
   if count~=1 then error('Подключите ровно одну IXUS 65.') end
  end
  local b=verified_build or remote('return get_buildinfo()')
  if b.platform~='ixus65_sd630' or b.platsub~='100a' then error('Это приложение рассчитано на IXUS 65 / SD630 с прошивкой 100A.') end
  verified_build=b
  action=action or os.getenv('IXUS_ACTION') or 'status'
  value=tonumber(value or os.getenv('IXUS_VALUE'))
  output=output or os.getenv('IXUS_OUTPUT')
  if action=='status' then
   local modes=remote([[local c=require'capmode'; local r={}; for k,v in pairs(c.mode_to_name) do if type(k)=='number' and c.valid(k) and not v:match('^VIDEO') then r[tostring(k)]=v end end return r]])
   return {state=state(),build=b,modes=modes,live=con:live_is_api_compatible(),displaySupported=remote('return type(set_backlight)=="function"')}
  elseif action=='poll' then
   return {state=state()}
  elseif action=='display' then
   assert(value==0 or value==1,'Недопустимое состояние экрана')
   -- Mark before sending: a timeout may occur after the camera changed the LCD.
   if value==0 then restore_display_needed=true end
   remote(('assert(type(set_backlight)=="function","Управление подсветкой недоступно"); set_backlight(%d); sleep(200)'):format(value))
   hold_backlight_off=value==0
   restore_display_needed=value==0
   return {}
  elseif action=='live' then
   assert(con:live_is_api_compatible(),'Live View недоступен')
   if not remote('return get_mode()') then local s,e=cli:execute('rec'); assert(s,e) end
   return {state=state()}
  elseif action=='play' then
   if remote('return get_mode()') then local s,e=cli:execute('play'); assert(s,e) end
   return {state=state()}
  elseif action=='frame' then
   assert(output and con:live_is_api_compatible(),'Live View недоступен')
   con:live_get_frame(1)
   -- Upstream live_dump_vp_pbm halves the header width twice when skip=true.
   -- Write the actual decoded pixel dimensions and payload instead.
   local p=require('liveimg').get_viewport_pimg(nil,con.live._frame,true)
   assert(p,'Камера не передала изображение')
   local f=assert(io.open(output,'wb'))
   f:write(('P6\n%d %d\n255\n'):format(p:width(),p:height()))
   p:to_lbuf_packed_rgb():fwrite(f); f:close()
   return {file=output}
  elseif action=='record' then
   if not remote('return get_mode()') then local s,e=cli:execute('rec'); assert(s,e) end
   return {state=state()}
  elseif action=='capture' then
   assert(output and not output:find('[\r\n"]'),'Некорректный путь')
   local rec=remote('return get_mode()'); if not rec then local s,e=cli:execute('rec'); assert(s,e) end
   assert(not remote([[return require'capmode'.get_name()]]):match('^VIDEO'),'Выберите режим фотосъёмки вместо видео')
   local s,e=cli:execute('shoot -raw=0 -dl="'..output..'"'); assert(s,e)
   local f=assert(io.open(output,'rb'),'JPEG не скачан'); local size=f:seek('end'); f:close(); assert(size>0,'Пустой JPEG')
   return {file=output,state=state()}
  else
   if not remote('return get_mode()') then local s,e=cli:execute('rec'); assert(s,e) end
   if action=='flash' then
    assert(value==0 or value==1 or value==2,'Недопустимая вспышка')
    remote(('set_prop(require("propcase").FLASH_MODE,%d); sleep(200)'):format(value))
    assert(state().flash==value,'Камера не приняла настройку вспышки')
   elseif action=='mode' then
    assert(value and value>0 and value%1==0,'Недопустимый режим')
    remote(([[local c=require'capmode'; local name=c.mode_to_name[%d]; assert(name and not name:match('^VIDEO') and c.valid(%d),'Режим фотосъёмки недоступен'); assert(c.set(%d)); sleep(700)]]):format(value,value,value))
    assert(state().mode==value,'Камера не переключила режим')
   elseif action=='zoom' then
    assert(value and value>=0 and value<=6 and value%1==0,'Недопустимый зум')
    remote(('set_zoom(%d); sleep(400)'):format(value))
    assert(state().zoom==value,'Камера не приняла положение зума')
   elseif action=='focusrange' then
    assert(value==0 or value==1 or value==3,'Недопустимый диапазон фокуса')
    -- Use the native Canon button rather than writing a property that may only
    -- change the reported value without changing the lens/Canon focus policy.
    remote(([[local p=require'propcase'; assert(p.REAL_FOCUS_MODE,'Диапазон фокуса недоступен');
      local target=%d; local original=get_prop(p.REAL_FOCUS_MODE); local locked=get_prop(p.AF_LOCK)==1;
      assert(original==0 or original==1 or original==3,'Неизвестный диапазон фокуса камеры');
      set_aflock(false);
      for i=1,3 do
        if get_prop(p.REAL_FOCUS_MODE)==target then return end
        click('left'); sleep(350)
      end
      if get_prop(p.REAL_FOCUS_MODE)==target then return end
      for i=1,3 do
        if get_prop(p.REAL_FOCUS_MODE)==original then break end
        click('left'); sleep(350)
      end
      set_aflock(locked);
      error('Камера не приняла диапазон фокуса в текущем режиме. Закройте меню камеры и попробуйте в режиме P.')]]):format(value))
    assert(state().focusRange==value,'Камера не переключила диапазон фокуса')
   elseif action=='focus' then
    assert(value and value>=100 and value<=10000,'Дистанция: 100–10000 мм')
    remote(('set_aflock(true); set_focus(%d); sleep(500)'):format(value))
    assert(state().aflock==1,'Камера не включила блокировку фокуса')
   elseif action=='autofocus' then remote('set_aflock(false); sleep(100)'); assert(state().aflock==0,'Камера не отключила блокировку фокуса')
   else error('Неизвестная команда') end
   return {state=state()}
  end
 end)
 if not ok then
  restore_display()
  hold_backlight_off=false
  verified_build=nil
  pcall(function() con:disconnect() end)
 end
 if ok then result.keepBacklightOff=hold_backlight_off end
 local response=ok and {ok=true,result=result} or {ok=false,error=tostring(result):gsub('^.-:%d+: ','')}
 response.requestID=request_id
 response.connectionGeneration=connection_generation
 print('IXUS_RESULT:'..json(response))
end
-- One helper process and one USB session serve all requests until stdin closes.
-- Paths are UTF-8 hex, never executable Lua or shell text.
function M.worker()
 io.stdout:setvbuf('no')
 for line in io.lines() do
  if line=='QUIT' then break end
  local action,value,hex,id=line:match('^([a-z]+)\t([%-0-9]*)\t([0-9a-f]*)\t(%d+)$')
  if action and #hex%2==0 then
   local output=hex:gsub('..',function(pair) return string.char(tonumber(pair,16)) end)
   M.run(action,value~='' and tonumber(value) or nil,output~='' and output or nil,tonumber(id))
  else
   print('IXUS_RESULT:'..json({ok=false,error='Некорректный запрос'}))
  end
 end
 restore_display()
 pcall(function() con:disconnect() end)
end
return M
