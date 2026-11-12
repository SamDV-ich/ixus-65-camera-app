-- One camera-side script keeps Canon menus alive across commands and state reads.
local M={}
function M.source(state_code,keep_off)
 return 'local keep_off='..tostring(keep_off)..'\nlocal function camera_state()\n'..state_code..'\nend\n'..[=[
local names={[0]='Menu',[1]='Func',[2]='Up',[3]='Down',[4]='Left',[5]='Right',[6]='Disp',[7]='Tele',[8]='Wide',[9]='Set'}
local kind=nil
local held=nil
local half=false
local normal_exit=false
function restore()
 exit_alt()
 if held then post_levent_for_npt('Unpress'..held..'Button') end
 if half then post_levent_for_npt('UnpressSwOne') end
 if not normal_exit and keep_off then set_backlight(1) end
end
local function button(name)
 assert(get_levent_def('Press'..name..'Button') and get_levent_def('Unpress'..name..'Button'),'Canon event unavailable')
 held=name
 local post=(name=='Menu' or name=='Disp') and post_levent_to_ui or post_levent_for_npt
 post('Press'..name..'Button'); sleep(100)
 post('Unpress'..name..'Button'); held=nil
 sleep(250)
end
exit_alt(); sleep(150)
write_usb_msg({ok=true})
local last=get_tick_count()
while get_tick_count()-last<12000 do
 local message=read_usb_msg(100)
 if keep_off then set_backlight(0) end
 if message then
  last=get_tick_count()
  if message=='quit' then
   if kind=='menu' then button('Menu') elseif kind=='func' then button('Set') end
   normal_exit=true
   write_usb_msg({ok=true})
   return
  elseif message=='state' or message=='ping' then
   write_usb_msg({ok=true,state=camera_state()})
  elseif message:match('^range:') then
   local target=tonumber(message:match('^range:(%d+)$'))
   local p=require'propcase'
   if kind or (target~=0 and target~=1 and target~=3) then
    write_usb_msg({ok=false,error='Close Canon menus before changing focus range'})
   else
    local original=get_prop(p.REAL_FOCUS_MODE); local locked=get_prop(p.AF_LOCK)==1
    set_aflock(false)
    for i=1,3 do if get_prop(p.REAL_FOCUS_MODE)==target then break end; button('Macro') end
    local applied=get_prop(p.REAL_FOCUS_MODE)==target
    if not applied then
     for i=1,3 do if get_prop(p.REAL_FOCUS_MODE)==original then break end; button('Macro') end
     set_aflock(locked)
    end
    write_usb_msg({ok=applied,error=not applied and 'Focus range unavailable in this camera mode' or nil,state=camera_state()})
   end
  elseif message=='backlight:0' or message=='backlight:1' then
   keep_off=message=='backlight:0'; set_backlight(keep_off and 0 or 1)
   write_usb_msg({ok=true})
  else
   local value=tonumber(message:match('^key:(%d+)$'))
   local combo=value and value>=100
   local key=combo and value-100 or value
   if not names[key] then
    write_usb_msg({ok=false,error='Invalid Canon key'})
   else
    local ready=true
    if combo then
     half=true; post_levent_for_npt('PressSwOne')
     local started=get_tick_count()
     repeat sleep(50) until get_shooting() or get_tick_count()-started>5000
     ready=get_shooting()
    end
    if ready then
     if key==1 and kind=='menu' then button('Menu'); kind=nil end
     button(names[key])
     if key==0 then if kind~='func' then if kind=='menu' then kind=nil else kind='menu' end end
     elseif key==1 then kind='func'
     elseif key==9 and kind=='func' then kind=nil end
    end
    if half then post_levent_for_npt('UnpressSwOne'); half=false end
    write_usb_msg({ok=ready,error=not ready and 'Camera half-press timed out' or nil,state=camera_state()})
   end
  end
 end
end
]=]
end
-- IXUS 65 native MENU panels are almost fully opaque; FUNC and the shooting
-- OSD leave most of the viewport transparent. Inspect bitmap alpha, not scene RGB.
function M.is_main_bitmap(bitmap)
 if not bitmap then return false end
 local data=bitmap:to_lbuf_packed_rgba():string()
 local count,opaque=0,0
 for i=4,#data,64 do
  count=count+1
  if data:byte(i)>=192 then opaque=opaque+1 end
 end
 return count>0 and opaque/count>=0.8
end
return M
