-- Host-side adapter for the IXUS 65 profile; modes are validated by camera CHDK.
local M={}
local profile=require'ixus_profile'
local function json(v)
 if type(v)=='boolean' or type(v)=='number' then return tostring(v) end
 if v==nil then return 'null' end
 if type(v)=='string' then return '"'..v:gsub('[%z\1-\31\\"]',function(c) return string.format('\\u%04x',c:byte()) end)..'"' end
 local count=0; local array=#v>0
 for k in pairs(v) do count=count+1; if type(k)~='number' or k<1 or k%1~=0 or k>#v then array=false end end
 local out={}
 if array and count==#v then
  for i=1,#v do out[#out+1]=json(v[i]) end
  return '['..table.concat(out,',')..']'
 end
 for k,x in pairs(v) do out[#out+1]=json(tostring(k))..':'..json(x) end
 return '{'..table.concat(out,',')..'}'
end
local menu_active=false
local native_main=false
local function menu_rpc(message)
 con:write_msg(message)
 local reply=con:wait_msg({mtype='user',munserialize=true,timeout=8000,poll=50})
 assert(reply and reply.ok,reply and reply.error or 'Нет ответа меню Canon')
 return reply
end
local function stop_menu()
 if not menu_active then return end
 menu_rpc('quit')
 local status=con:wait_status({run=false,timeout=3000,poll=50})
 assert(not status.timeout,'Меню Canon не завершилось')
 con:flushmsgs()
 menu_active=false
end
local function remote(code)
 assert(not menu_active,'Сначала закройте меню камеры')
 return con:execwait(code,{timeout=60000})
end
local half_may_be_held=false
local function remote_half(code)
 half_may_be_held=true
 local result=remote(code)
 half_may_be_held=false
 return result
end
local function main_visible()
 con:live_get_frame(13)
 local bitmap=require('liveimg').get_bitmap_pimg(nil,con.live._frame,false)
 return require('ixus_menu').is_main_bitmap(bitmap)
end
local function close_main(force)
 if not native_main and not force then return true end
 native_main=false
 if not main_visible() then return true end
 -- MENU backs out without confirming values or starting autofocus. Inspect the
 -- bitmap after each step so nested native menus cannot be mistaken for exit.
 for i=1,5 do
  remote("click('menu'); sleep(350)")
  if not main_visible() then return true end
 end
 native_main=true
 return false
end
local show_osd=false
local hold_backlight_off=false
local function state()
 -- An explicit keep-off policy also handles Canon buttons that wake the lamp.
 -- Reapply within the existing state request, not in the frame-transfer loop.
 local prefix=hold_backlight_off and 'set_backlight(0); ' or ''
 local query=[[local p=require'propcase'; local c=require'capmode'; return {mode=c.get(),modeName=c.get_name(),flash=get_prop(p.FLASH_MODE),zoom=get_zoom(),focus=get_focus(),aflock=get_prop(p.AF_LOCK),focusState=p.FOCUS_STATE and get_prop(p.FOCUS_STATE) or nil,focusRange=p.REAL_FOCUS_MODE and get_prop(p.REAL_FOCUS_MODE) or nil,record=get_mode(),battery=get_vbatt(),batteryMin=get_config_value(2101),batteryMax=get_config_value(2100),settings={quality=get_prop(p.QUALITY or 23),resolution=get_prop(p.RESOLUTION or 24),iso=get_prop(p.ISO_MODE or 21),wb=get_prop(p.WB_MODE or 5),ev=get_prop(p.EV_CORRECTION_1 or 25),metering=get_prop(p.METERING_MODE or 9)}}]]
 local result=menu_active and menu_rpc('state').state or remote(prefix..query)
 result.controls=profile.controls(result.modeName)
 return result
end
local state_query=[[local p=require'propcase'; local c=require'capmode'; return {mode=c.get(),modeName=c.get_name(),flash=get_prop(p.FLASH_MODE),zoom=get_zoom(),focus=get_focus(),aflock=get_prop(p.AF_LOCK),focusState=p.FOCUS_STATE and get_prop(p.FOCUS_STATE) or nil,focusRange=p.REAL_FOCUS_MODE and get_prop(p.REAL_FOCUS_MODE) or nil,record=get_mode(),battery=get_vbatt(),batteryMin=get_config_value(2101),batteryMax=get_config_value(2100),settings={quality=get_prop(p.QUALITY or 23),resolution=get_prop(p.RESOLUTION or 24),iso=get_prop(p.ISO_MODE or 21),wb=get_prop(p.WB_MODE or 5),ev=get_prop(p.EV_CORRECTION_1 or 25),metering=get_prop(p.METERING_MODE or 9)}}]]
local function start_menu()
 if menu_active then return end
 assert(con:live_is_api_compatible(),'Экран камеры недоступен')
 if not remote('return get_mode()') then local s,e=cli:execute('rec'); assert(s,e) end
 assert(close_main(true),'Закройте меню камеры кнопкой MENU')
 con:exec(require('ixus_menu').source(state_query,hold_backlight_off),{wait=false})
 local ready=con:wait_msg({mtype='user',munserialize=true,timeout=5000,poll=50})
 assert(ready and ready.ok,'Меню камеры не запустилось')
 menu_active=true
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
   stop_menu(); close_main()
   local modes=remote([[local c=require'capmode'; local r={}; for k,v in pairs(c.mode_to_name) do if type(k)=='number' and c.valid(k) and not v:match('^VIDEO') then r[tostring(k)]=v end end return r]])
   return {state=state(),build=b,modes=modes,live=con:live_is_api_compatible(),displaySupported=remote('return type(set_backlight)=="function"')}
  elseif action=='poll' then
   return {state=state()}
  elseif action=='display' then
   assert(value==0 or value==1,'Недопустимое состояние экрана')
   -- Mark before sending: a timeout may occur after the camera changed the LCD.
   if value==0 then restore_display_needed=true end
   if menu_active then
    menu_rpc('backlight:'..value)
   else
   remote(('assert(type(set_backlight)=="function","Управление подсветкой недоступно"); set_backlight(%d); sleep(200)'):format(value))
   end
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
  elseif action=='screen' then
   assert(value==0 or value==1,'Недопустимый экран')
   if value==0 then stop_menu(); close_main(true)
   elseif not remote('return get_mode()') then local s,e=cli:execute('rec'); assert(s,e) end
   show_osd=value==1
   return {state=state()}
  elseif action=='key' then
   assert(show_osd,'Сначала откройте настройки камеры')
   assert(value and value%1==0 and ((value>=0 and value<=9) or (value>=100 and value<=109)),'Недопустимая кнопка камеры')
   local combo=value>=100
   local key=combo and value-100 or value
   if key==0 and menu_active then
    local reply=menu_rpc('key:'..value)
    if reply.state then reply.state.controls=profile.controls(reply.state.modeName) end
    return {state=reply.state}
   end
   if key==0 then
    stop_menu()
    remote("click('menu'); sleep(350)")
    native_main=not native_main
    return {state=state()}
   end
   if (key==1 or combo) and not menu_active and not close_main(true) then
    return {state=state(),warning='Закройте меню камеры кнопкой MENU и повторите.'}
   end
   if native_main then
    local names={[2]='Up',[3]='Down',[4]='Left',[5]='Right',[6]='Disp',[7]='Tele',[8]='Wide',[9]='Set'}
    local name=assert(names[key],'Недопустимая кнопка камеры')
    remote(("post_levent_for_npt('Press%sButton'); sleep(100); post_levent_for_npt('Unpress%sButton'); sleep(350)"):format(name,name))
    return {state=state()}
   end
   start_menu()
   local reply=menu_rpc('key:'..value)
   if reply.state then reply.state.controls=profile.controls(reply.state.modeName) end
   return {state=reply.state}
  elseif action=='frame' then
   assert(output and con:live_is_api_compatible(),'Live View недоступен')
   if menu_active then menu_rpc('ping') end
   con:live_get_frame(show_osd and 13 or 1)
   -- Upstream live_dump_vp_pbm halves the header width twice when skip=true.
   -- Write the actual decoded pixel dimensions and payload instead.
   assert(value==nil or value==0 or value==1,'Некорректное качество предпросмотра')
   local p=require('liveimg').get_viewport_pimg(nil,con.live._frame,value~=1)
   assert(p,'Камера не передала изображение')
   local f=assert(io.open(output,'wb'))
   f:write(('P6\n%d %d\n255\n'):format(p:width(),p:height()))
   p:to_lbuf_packed_rgb():fwrite(f); f:close()
   if show_osd then
    local bm=require('liveimg').get_bitmap_pimg(nil,con.live._frame,false)
    assert(bm,'Камера не передала экранное меню')
    if not menu_active then native_main=require('ixus_menu').is_main_bitmap(bm) end
    local path=output..'.rgba'; local overlay=assert(io.open(path,'wb'))
    overlay:write(('RGBA\n%d %d\n'):format(bm:width(),bm:height()))
    bm:to_lbuf_packed_rgba():fwrite(overlay); overlay:close()
    return {file=output,overlay=path}
   end
   return {file=output}
  elseif action=='record' then
   if not remote('return get_mode()') then local s,e=cli:execute('rec'); assert(s,e) end
   return {state=state()}
  elseif action=='take' then
   stop_menu(); assert(close_main(),'Закройте меню камеры')
   if not remote('return get_mode()') then local s,e=cli:execute('rec'); assert(s,e) end
   assert(not remote([[return require'capmode'.get_name()]]):match('^VIDEO'),'Выберите режим фотосъёмки вместо видео')
   local result=require('ixus_capture').take(con,value,output)
   result.state=state()
   return result
  elseif action=='finishcapture' then
   return require('ixus_capture').finish(con)
  elseif action=='capture' then
   assert(output and not output:find('[\r\n"]'),'Некорректный путь')
   local rec=remote('return get_mode()'); if not rec then local s,e=cli:execute('rec'); assert(s,e) end
   assert(not remote([[return require'capmode'.get_name()]]):match('^VIDEO'),'Выберите режим фотосъёмки вместо видео')
   local s,e=cli:execute('shoot -raw=0 -dl="'..output..'"'); assert(s,e)
   local f=assert(io.open(output,'rb'),'JPEG не скачан'); local size=f:seek('end'); f:close(); assert(size>0,'Пустой JPEG')
   return {file=output,state=state()}
  else
   if action~='focusnow' and not remote('return get_mode()') then local s,e=cli:execute('rec'); assert(s,e) end
   if action=='iso' or action=='wb' or action=='ev' or action=='metering' then
    assert(profile.allows(state().controls,action,value),'Настройка недоступна в этом режиме')
    local props={iso='ISO_MODE',wb='WB_MODE',ev='EV_CORRECTION_1',metering='METERING_MODE'}
    local fallback={iso=21,wb=5,ev=25,metering=9}
    remote(([[local p=require'propcase'; local id=p.%s or %d; set_prop(id,%d);
     %s sleep(200)]]):format(props[action],fallback[action],value,action=='ev' and ('set_prop(p.EV_CORRECTION_2 or 26,'..value..');') or ''))
    assert(state().settings[action]==value,'Камера не приняла значение настройки')
   elseif action=='flash' then
    assert(profile.allows(state().controls,'flash',value),'Вспышка недоступна в этом режиме')
    remote(('set_prop(require("propcase").FLASH_MODE,%d); sleep(200)'):format(value))
    assert(state().flash==value,'Камера не приняла настройку вспышки')
   elseif action=='mode' then
    assert(value and value>0 and value%1==0,'Недопустимый режим')
    remote(([[local c=require'capmode'; local name=c.mode_to_name[%d]; assert(name and not name:match('^VIDEO') and c.valid(%d),'Режим фотосъёмки недоступен'); assert(c.set(%d)); sleep(700)]]):format(value,value,value))
    assert(state().mode==value,'Камера не переключила режим')
   elseif action=='zoom' then
    assert(profile.allows(state().controls,'zoom',value),'Зум недоступен в этом режиме')
    remote(('set_zoom(%d); sleep(400)'):format(value))
    assert(state().zoom==value,'Камера не приняла положение зума')
   elseif action=='focusrange' then
    assert(profile.allows(state().controls,'focusrange',value),'Диапазон фокуса недоступен в этом режиме')
    local temporary=not menu_active
    start_menu()
    menu_rpc('range:'..value)
    if temporary then stop_menu() end
    assert(state().focusRange==value,'Камера не переключила диапазон фокуса')
   elseif action=='focuslock' then
    assert(value==0 or value==1,'Недопустимая фиксация фокуса')
    assert(profile.allows(state().controls,'focuslock',value),'Фиксация фокуса недоступна в этом режиме')
    remote(('set_aflock(%s); sleep(100)'):format(value==1 and 'true' or 'false'))
    assert(state().aflock==value,'Камера не приняла фиксацию фокуса')
   elseif action=='focusnow' then
    assert(value==0 or value==1,'Недопустимая фиксация фокуса')
    local report=remote_half(([[local p=require'propcase';
      if not get_mode() then
       set_record(1); local t=get_tick_count(); repeat sleep(100) until get_mode() or get_tick_count()-t>5000;
       assert(get_mode(),'Камера не перешла в съёмку'); sleep(500)
      end
      local name=require'capmode'.get_name();
      assert(%d==0 or name=='P' or name=='DIGITAL_MACRO' or name=='LONG_SHUTTER','Фиксация фокуса недоступна в этом режиме');
      set_aflock(false); press('shoot_half'); local started=get_tick_count(); local focused=false;
      repeat sleep(50); focused=get_focus_ok() until focused or get_tick_count()-started>5000;
      local result={focused=focused,shooting=get_shooting(),state=get_prop(p.FOCUS_STATE),distance=get_focus(),elapsed=get_tick_count()-started};
      if focused and %d==1 then set_aflock(true) end
      release('shoot_half');
      return result]]):format(value,value))
    if not report.focused then
     print(('IXUS_DEBUG: focus ready=%s state=%s distance=%s elapsed=%s'):format(tostring(report.shooting),tostring(report.state),tostring(report.distance),tostring(report.elapsed)))
     return {state=state(),focusSucceeded=false,warning='Камера не подтвердила резкость. Для близкого предмета выберите «Макро» или наведите камеру на более контрастную деталь.'}
    end
    return {state=state(),focusSucceeded=true}
   elseif action=='focus' then
    assert(profile.allows(state().controls,'focus',1),'Ручная дистанция недоступна в этом режиме')
    assert(value and value>=100 and value<=10000,'Дистанция: 100–10000 мм')
    remote(('set_aflock(true); set_focus(%d); sleep(500)'):format(value))
    assert(state().aflock==1,'Камера не включила блокировку фокуса')
   elseif action=='autofocus' then remote('set_aflock(false); sleep(100)'); assert(state().aflock==0,'Камера не отключила блокировку фокуса')
   else error('Неизвестная команда') end
   return {state=state()}
  end
 end)
 if not ok then
  if native_main and con:is_connected() then pcall(close_main) end
  native_main=false
  if menu_active and con:is_connected() then pcall(stop_menu) end
  menu_active=false
  if half_may_be_held and con:is_connected() then
   pcall(function() remote("release('shoot_half'); post_levent_for_npt('UnpressSwOne')") end)
  end
  half_may_be_held=false
  restore_display()
  hold_backlight_off=false
  show_osd=false
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
 pcall(stop_menu)
 pcall(close_main)
 restore_display()
 pcall(function() con:disconnect() end)
end
return M
