addon.name = "toastynotif"
addon.author = "Reyuu"
addon.version = "0.2" -- incremental versioning +0.1 scale
addon.desc = "This addon adds toast notifications"

--------------------------
--- 
--- COMMON
--- 
--------------------------

require('common')
require("sugar")
local settings = require("settings")
local imgui = require('imgui')
local flux = require("flux")
local socket = require("socket")
local d3d = require('d3d8')
local ffi = require('ffi')
local bit = require("bit")
local C = ffi.C

local d3d8dev = d3d.get_device()
local _, main_viewport = d3d8dev:GetViewport()
local resolution = T{ x=main_viewport.Width, y=main_viewport.Height }

local queue = T{}
local drawn_objects = T{}

local last_frame = nil
local current_frame = nil
local dt = 0
local settings_window_display = { false }

local sounds_directory = addon.path:append('\\assets\\')
local sounds_files = {}

local addon_default_settings = T{
    animation=T{
        horizontal = "to_right", -- valid options: to_left, to_right
        wait_before_moving=1,
        length = 1.2,
    },
    position=T{
        to_right=T{
            x=resolution.x - 310, -- - (padding - rectangle.width)
            y=resolution.y/2,
        },
        to_left=T{
            x=70, -- padding - rectangle.width
            y=resolution.y/2
        }
    },
    rectangle=T{
        width=250,
        height = 60,
    },
    padding=10,
    max_slots=3,
    inverted_direction=true,
    sound="ffvii_sound0.wav"
}


local addon_settings = settings.load(addon_default_settings)

local item_cache = {}

local function cache_item(item_id)
    local item = AshitaCore:GetResourceManager():GetItemById(item_id);
    if item == nil then
        return false
    end
    item_cache[tostring(item.Name[1]):lower()] = item_id
    item_cache[tostring(item.LogNameSingular[1]):lower()] = item_id
    item_cache[tostring(item.LogNamePlural[1]):lower()] = item_id
    return true
end

local function get_sounds_in_directory()
    for f in io.popen("dir \""..sounds_directory.."\" /b"):lines() do
        table.insert(sounds_files, f)
    end
end

local function update_settings(s)
    if not(s == nil) then
        --addon_settings = s
        settings.save()
    end
end

local function get_free_slot()
    for i=1,tonumber(addon_settings.max_slots) do
        if drawn_objects[i] == nil then
            return i
        end
    end
    return 0
end

local function print_r (t)
    --modified print_r for debugging
    local print_r_cache={}
    local function sub_print_r(t,indent)
        if (print_r_cache[tostring(t)]) then
            print(indent.."*"..tostring(t))
        else
            print_r_cache[tostring(t)]=true
            if (type(t)=="table") then
                for pos,val in pairs(t) do
                    if (type(val)=="table") then
                        print(indent.."["..pos.."] => "..tostring(t).." {")
                        sub_print_r(val,indent..string.rep(" ",string.len(pos)+8))
                        print(indent..string.rep(" ",string.len(pos)+6).."}")
                    elseif (type(val)=="string") then
                        print(indent.."["..pos..'] => "'..val..'"')
                    else
                        print(indent.."["..pos.."] => "..tostring(val))
                    end
                end
            else
                print(indent..tostring(t))
            end
        end
    end
    if (type(t)=="table") then
        print(tostring(t).." {")
        sub_print_r(t,"  ")
        print("}")
    else
        sub_print_r(t,"  ")
    end
    print()
end

function file_exists(name)
    local f=io.open(name,"r")
    if f~=nil then io.close(f) return true else return false end
 end
 

local function play_sound(s)
    local sound_path = sounds_directory:append(s)
    if file_exists(sound_path) then
        ashita.misc.play_sound(sound_path)
    end
end

-- what in tarnation is going on here.
-- stolen from equipmon codebase
local function load_item_texture_pointer(itemid)
    if (T{ nil, 0, -1, 65535 }:hasval(itemid)) then
        return nil;
    end

    local item = AshitaCore:GetResourceManager():GetItemById(itemid);
    if (item == nil) then return nil end;

    local texture_ptr = ffi.new('IDirect3DTexture8*[1]');
    if (C.D3DXCreateTextureFromFileInMemoryEx(d3d8dev, item.Bitmap, item.ImageSize, 0xFFFFFFFF, 0xFFFFFFFF, 1, 0, C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED, C.D3DX_DEFAULT, C.D3DX_DEFAULT, 0xFF000000, nil, nil, texture_ptr) ~= C.S_OK) then
        return nil;
    end

    return d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', texture_ptr[0]));
end

--------------------------
--- 
--- DRAWABLE OBJECT DEFINITIONS
--- 
--------------------------

local function drawable_init()
    return {
        x = addon_settings.padding, -- anything for debugging
        y = addon_settings.padding, -- anything for debugging
        text="a sheepskin",
        count=-1,
        done=false,
        wait_before_moving=addon_settings.animation.wait_before_moving,
        till=addon_settings.animation.length,
        slot=-1,
        item_icon=nil,
    }
end

local function drawable_draw(d)
    if d.done then
        return {d, false}
    end
    imgui.SetNextWindowPos({d.x, d.y}, 0)
    imgui.SetNextWindowSize({addon_settings.rectangle.width, addon_settings.rectangle.height})
    local window_flags = ImGuiWindowFlags_NoDecoration
    imgui.Begin("overlay" .. d.slot, true, window_flags)
    imgui.SetCursorPosY(addon_settings.rectangle.height/2 - 16)
    if not(d.item_icon == nil) then
        imgui.Image(tonumber(ffi.cast('uint32_t', d.item_icon)), {32, 32}, {0, 0}, {1, 1}, {255, 255, 255, 255})
    end
    imgui.SameLine()
    imgui.SetCursorPosY(addon_settings.rectangle.height/2 - imgui.GetTextLineHeight()/2)
    imgui.Text(d.text)
    imgui.End()

    return {d,}
end

local function calculate_dt()
    last_frame = current_frame;
    current_frame = socket.gettime();
    if not(last_frame == nil) and not(current_frame == nil) then
        dt = current_frame - last_frame
    end
end

--------------------------
--- 
--- TOAST NOTIFICATION METHODS
--- 
--------------------------

local function toast_update()
    local updating_slots = true
    local iteration_count = 0
    local slot_updated = false
    while updating_slots do
        local slot = get_free_slot()
        if not(slot == 0) then
            if not(queue[1] == nil) then
                drawn_objects[slot] = queue[1]
                drawn_objects[slot].slot = slot

                drawn_objects[slot].x = addon_settings.position[addon_settings.animation.horizontal].x
                drawn_objects[slot].y = addon_settings.position[addon_settings.animation.horizontal].y
                if addon_settings.inverted_direction then
                    drawn_objects[slot].y = drawn_objects[slot].y - ((addon_settings.rectangle.height + addon_settings.padding) * (slot - 1))
                else
                    drawn_objects[slot].y = drawn_objects[slot].y + ((addon_settings.rectangle.height + addon_settings.padding) * (slot - 1))
                end
                local searchable_string = drawn_objects[slot].text
                searchable_string = string.gsub(searchable_string, "%d+ ", "")
                searchable_string = string.gsub(searchable_string, "a ", "")
                searchable_string = string.gsub(searchable_string, "an ", "")
                searchable_string = string.gsub(searchable_string, "the ", "")
                local cached_item = item_cache[searchable_string:lower()]

                local item_id = nil
                if not(cached_item == nil) then
                    item_id = cached_item
                else
                    -- there are all of thosee weird quantifiers for items, hangup from japanese version probably
                    searchable_string = string.gsub(searchable_string, "pot of ", "")
                    searchable_string = string.gsub(searchable_string, "bag of ", "")
                    searchable_string = string.gsub(searchable_string, "clump of ", "")
                    searchable_string = string.gsub(searchable_string, "strip of ", "")
                    searchable_string = string.gsub(searchable_string, "slice of ", "")
                    if searchable_string == "gil" then
                        searchable_string = "Counterfeit Gil"
                    end
                    item_id = AshitaCore:GetResourceManager():GetItemByName(searchable_string, 2)
                    if not(item_id == nil) then
                        item_id = item_id.Id
                    end
                end

                if not(item_id == nil) then
                    drawn_objects[slot].item_icon = load_item_texture_pointer(item_id)
                end
                
                -- Animations 
                if addon_settings.animation.horizontal == "to_left" then
                    local to_x = drawn_objects[slot].x
                    drawn_objects[slot].x = to_x - addon_settings.rectangle.width - addon_settings.padding

                    flux.to(drawn_objects[slot], 0.2, {x = to_x})
                        :after(drawn_objects[slot], drawn_objects[slot].till, {x = (-addon_settings.rectangle.width) - addon_settings.padding*2})
                        :ease("cubicout")
                        :delay(drawn_objects[slot].wait_before_moving)
                        :oncomplete(function() drawn_objects[slot].done = true end)
                end
                
                if addon_settings.animation.horizontal == "to_right" then
                    local to_x = drawn_objects[slot].x
                    drawn_objects[slot].x = to_x + addon_settings.rectangle.width + addon_settings.padding

                    flux.to(drawn_objects[slot], 0.2, {x = to_x})
                        :after(drawn_objects[slot], drawn_objects[slot].till, {x = resolution.x + addon_settings.rectangle.width + addon_settings.padding*2})
                        :ease("cubicout")
                        :delay(drawn_objects[slot].wait_before_moving)
                        :oncomplete(function() drawn_objects[slot].done = true end)
                end
                table.remove(queue, 1)
                slot_updated = true
            end
        end
        iteration_count = iteration_count + 1 -- emergency break
        if (slot == 0 or iteration_count >= addon_settings.max_slots) then
            updating_slots = false
            break
        end
    end
    if slot_updated then
        play_sound(addon_settings.sound)
    end
    local keys_to_delete = {}
    for i, v in ipairs(drawn_objects) do
        if not(v == nil) then
            if drawn_objects[i].done then
                table.insert(keys_to_delete, i)
            end
        end
    end
    if #keys_to_delete > 0 then
        for i, v in ipairs(keys_to_delete) do
            drawn_objects[v] = nil
        end
    end
end

local function toast_render()
    for i, v in ipairs(drawn_objects) do
        if not(v == nil) then
            drawn_objects[i], _ = unpack(drawable_draw(v))
        end
    end
end

local function toast_commands(e)
    if (e.command == "/toastynotif help") then
        local help_text = {
            "/toastynotif help - displays this help message",
            "/toastynotif test - tests the notification system (adds (max slots + 1) amount of items to the queue)",
            "/toastynotif settings - open configuration window"
        }
        for i, v in ipairs(help_text) do
            print(v)
        end
    end
    if (e.command == "/toastynotif test") then
        for i=1,addon_settings.max_slots+1,1 do
            local d = drawable_init()
            table.insert(queue, d)
        end
    end
    if (e.command == "/toastynotif settings") then
        settings_window_display[1] = not(settings_window_display[1])
    end
end

local function toast_text_in(e)
    local matched = nil
    for i,v in ipairs({ "Obtained: (.*)",
                        "Obtained key item: (.*)",
                        ".* obtains (.*)%.",
                        ".* obtains a temporary item: (.*)%."}) do
        matched = string.match(e.message, v)
        if not(matched == nil) then
            matched = string.gsub(matched, "[^%w%s]+", "")
            local notif = drawable_init()
            notif.text = matched
            table.insert(queue, notif)
            break
        end
    end
end

--------------------------
--- 
--- SETTINGS WINDOW
--- 
--------------------------

local function settings_window_render()

    if settings_window_display[1] then
        for i=1,addon_settings.max_slots,1 do
            if drawn_objects[i] == nil then
                local window_flags = ImGuiWindowFlags_NoDecoration
                if addon_settings.inverted_direction then
                    imgui.SetNextWindowPos({addon_settings.position[addon_settings.animation.horizontal].x,
                                            addon_settings.position[addon_settings.animation.horizontal].y - (addon_settings.rectangle.height + addon_settings.padding) * (i - 1)}, 0)
                else
                    imgui.SetNextWindowPos({addon_settings.position[addon_settings.animation.horizontal].x,
                                            addon_settings.position[addon_settings.animation.horizontal].y + (addon_settings.rectangle.height + addon_settings.padding) * (i - 1)}, 0)
                end
                imgui.SetNextWindowSize({addon_settings.rectangle.width, addon_settings.rectangle.height})
                imgui.Begin("overlay" .. i, true, window_flags)
                imgui.SetCursorPosY(addon_settings.rectangle.height/2 - 16)
                imgui.Image(tonumber(ffi.cast('uint32_t', load_item_texture_pointer(5686))), {32, 32}, {0, 0}, {1, 1}, {255, 255, 255, 255})
                imgui.SameLine()
                imgui.SetCursorPosY(addon_settings.rectangle.height/2 - imgui.GetTextLineHeight()/2)
                imgui.Text("Cheese sandwich +1")
                imgui.End()
            end
        end
    

        local settings_window_flags = bit.bor(ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoResize, ImGuiWindowFlags_NoCollapse)
        local settings_changed = false
        --imgui.SetNextWindowSize({500, 500}, ImGuiCond_None)
        if imgui.Begin("Settings##settings", settings_window_display, settings_window_flags) then
            local s = addon_settings
            if imgui.CollapsingHeader("Settings") then
                imgui.BeginTable("settings_table", 2)
                imgui.TableNextRow()
                imgui.TableNextColumn()
                imgui.Text("Animation type")

                imgui.TableNextColumn()
                local anim_type_cb_items = {"To left", "To right"}
                local anim_type_selected = 1
                if s.animation.horizontal == "to_right" then
                    anim_type_selected = 2
                end
                if imgui.BeginCombo("##anim_type_cb", anim_type_cb_items[anim_type_selected]) then
                    if imgui.Selectable("To left##to_left", choice == 1) then
                        s.animation.horizontal = "to_left"
                        settings_changed = true
                    end
                    if imgui.Selectable("To right##to_left", choice == 2) then
                        s.animation.horizontal = "to_right"
                        settings_changed = true
                    end
                    imgui.EndCombo()
                end
                
                imgui.TableNextRow()
                imgui.TableNextColumn()
                imgui.Text("Animation movement delay")
                imgui.TableNextColumn()
                local anim_delay = {s.animation.wait_before_moving}
                if imgui.InputFloat("##anim_delay", anim_delay, 0.1) then
                        s.animation.wait_before_moving = anim_delay[1]
                        settings_changed = true
                end
                
                imgui.TableNextRow()
                imgui.TableNextColumn()
                imgui.Text("Animation length")
                imgui.TableNextColumn()
                local anim_length = {s.animation.length}
                if imgui.InputFloat("##anim_length", anim_length, 0.1) then
                    s.animation.length = anim_length[1]
                    settings_changed = true
                end

                imgui.Separator()

                imgui.TableNextRow()
                imgui.TableNextColumn()
                imgui.Text("Position")
                imgui.TableNextColumn()
                local position = {s.position[s.animation.horizontal].x, s.position[s.animation.horizontal].y}
                if imgui.InputInt2('##to_right_position', position) then
                    s.position[s.animation.horizontal].x = position[1]
                    s.position[s.animation.horizontal].y = position[2]
                    settings_changed = true
                end

                imgui.TableNextRow()
                imgui.TableNextColumn()
                imgui.Text("Rectangle")
                imgui.TableNextColumn()
                local rectangle_size = {s.rectangle.width, s.rectangle.height}
                if imgui.InputInt2("##rectangle_height", rectangle_size) then
                    s.rectangle.width = rectangle_size[1]
                    s.rectangle.height = rectangle_size[2]
                    settings_changed = true
                end

                imgui.TableNextRow()
                imgui.TableNextColumn()
                imgui.Text("Padding")
                imgui.TableNextColumn()
                local padding = {s.padding}
                if imgui.InputInt("##padding", padding) then
                    s.padding = padding[1]
                    settings_changed = true
                end

                imgui.Separator()

                imgui.TableNextRow()
                imgui.TableNextColumn()
                imgui.Text("Max slots")
                imgui.TableNextColumn()
                local s_max_slots = {s.max_slots}
                if imgui.InputInt("##max_slots", s_max_slots) then
                    s.max_slots = s_max_slots[1]
                    settings_changed = true
                end

                imgui.TableNextRow()
                imgui.TableNextColumn()
                imgui.Text("Inverted")
                imgui.TableNextColumn()
                local s_inverted = {s.inverted_direction}
                if imgui.Checkbox("##inverted_dir", s_inverted) then
                    s.inverted_direction = s_inverted[1]
                end

                imgui.TableNextRow()
                imgui.TableNextColumn()
                imgui.Text("Sounds")
                imgui.TableNextColumn()
                if imgui.BeginCombo("##sound", s.sound) then
                    for i,v in ipairs(sounds_files) do
                        if imgui.Selectable(v.."##selectable_"..i, i == choice) then
                            s.sound = v
                            settings_changed = true
                        end
                    end
                    imgui.EndCombo()
                end
                if (imgui.Button("Preview")) then
                    play_sound(s.sound)
                end
                imgui.EndTable()
                
            end
            
            if imgui.CollapsingHeader("About") then
                imgui.Text("Created with <3 by @Reyuu (she/they) on GitHub.")
            end
            
            if settings_changed then
                addon_settings = s
                update_settings(s)
            end
        end
        imgui.End()
    end
end

--------------------------
--- 
--- ASHITA HOOKS
--- 
--------------------------
ashita.events.register("load", "load_callback1", function(e)
    current_frame = os.clock()
    get_sounds_in_directory()
end)

ashita.events.register('text_in', 'text_in_callback1', function (e)
    toast_text_in(e)
end)

ashita.events.register("command", "command_callback1", function(e)
    toast_commands(e)
end)

ashita.events.register("d3d_beginscene", "d3d_beginscene_callback1", function (isRenderingBackBuffer)
    -- just so we don't flood Ashita with updates
    if settings_window_display or not(next(drawn_objects) == nil) then
        calculate_dt()
        flux.update(dt)
        toast_update()
    end
end)

ashita.events.register("d3d_present", "d3d_present_callback1", function ()
    -- just so we don't flood Ashita with renders
    if settings_window_display or not(next(drawn_objects) == nil) then
        toast_render()
        settings_window_render()
    end
end)

ashita.events.register("packet_in", "packet_in_callback1", function (e)
    if (e.id == 0x00D2) then
        local item_id = struct.unpack("<h", e.data_modified, 0x11) -- this took 10 years off my life to figure out
        cache_item(item_id)
    end
end)