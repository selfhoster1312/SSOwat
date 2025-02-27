--
-- helpers.lua
--
-- This is a file called at every request by the `access.lua` file. It contains
-- a set of useful functions related to HTTP and LDAP.
--

module('helpers', package.seeall)

local cache = ngx.shared.cache
local conf = config.get_config()
local logger = require("log")

-- url parser, c.f. https://rosettacode.org/wiki/URL_parser#Lua
local url_parser = require "socket.url"

-- Import Perl regular expressions library
local rex = require "rex_pcre"

local is_logged_in = false

function refresh_config()
    conf = config.get_config()
end

function get_config()
    return conf
end

-- The 'match' function uses PCRE regex as default
-- If '%.' is found in the regex, we assume it's a LUA regex (legacy code)
-- 'match' returns the matched text.
function match(s, regex)
    if not string.find(regex, '%%%.') then
        return rex.match(s, regex)
    else
        return string.match(s,regex)
    end
end

-- Read a FS stored file
function read_file(file)
    local f = io.open(file, "rb")
    if not f then return false end
    local content = f:read("*all")
    f:close()
    return content
end


-- Lua has no sugar :D
function is_in_table(t, v)
    for key, value in ipairs(t) do
        if value == v then return key end
    end
end


-- Get the index of a value in a table
function index_of(t,val)
    for k,v in ipairs(t) do
        if v == val then return k end
    end
end


-- Test whether a string starts with another
function string.starts(String, Start)
    if not String then
        return false
    end
    return string.sub(String, 1, string.len(Start)) == Start
end


-- Test whether a string ends with another
function string.ends(String, End)
   return End=='' or string.sub(String, -string.len(End)) == End
end


-- Find a string by its translate key in the right language
function t(key)
   if conf.lang and i18n[conf.lang] and i18n[conf.lang][key] then
       return i18n[conf.lang][key]
   else
       return i18n[conf["default_language"]][key] or ""
   end
end


-- Store a message in the flash shared table in order to display it at the
-- next response
function flash(wat, message)
    if wat == "fail"
    or wat == "win"
    or wat == "info"
    then
        flashs[wat] = message
    end
end


-- Hash a string using hmac_sha512, return a hexa string
function hmac_sha512(key, message)
    local cache_key = key..":"..message

    if not cache:get(cache_key) then
        -- lua ecosystem is a disaster and it was not possible to find a good
        -- easily multiplatform integrable code for this
        --
        -- this is really dirty and probably leak the key and the message in the process list
        -- but if someone got there I guess we really have other problems so this is acceptable
        -- and also this is way better than the previous situation
        local pipe = io.popen("echo -n '" ..message:gsub("'", "'\\''").. "' | openssl dgst -sha512 -hmac '" ..key:gsub("'", "'\\''").. "'")

        -- openssl returns something like this:
        -- root@yunohost:~# echo -n "qsd" | openssl sha512 -hmac "key"
        -- SHA2-512(stdin)= f1c2b1658fe64c5a3d16459f2f4eea213e4181905c190235b060ab2a4e7d6a41c15ea2c246828537a1e32ae524b7a7ed309e6d296089194c3e3e3efb98c1fbe3
        --
        -- so we need to remove the "SHA2-512(stdin)= " at the beginning ("(stdin)= " on older openssl version)
        local line = pipe:read()
        local hash = line:sub(line:find("=") + 2)
        pipe:close()

        cache:set(cache_key, hash, conf["session_timeout"])
        return hash
    else
        return cache:get(cache_key)
    end
end


-- Convert a table of arguments to an URI string
function uri_args_string(args)
    if not args then
        args = ngx.req.get_uri_args()
    end
    String = "?"
    for k,v in pairs(args) do
        String = String..tostring(k).."="..tostring(v).."&"
    end
    return string.sub(String, 1, string.len(String) - 1)
end


-- Set the Cross-Domain-Authentication key for a specific user
function set_cda_key()
    local cda_key = random_string()
    cache:set("CDA|"..cda_key, authUser, 10)
    return cda_key
end


-- Compute and set the authentication cookie
--
-- Sets 3 cookies containing:
-- * The username
-- * The expiration time
-- * A hash of those information along with the client IP address and a unique
--   session key
--
-- It enables the SSO to quickly retrieve the username and the session
-- expiration time, and to prove their authenticity to avoid session hijacking.
--
function set_auth_cookie(user, domain)
    local maxAge = conf["session_max_timeout"]
    local expire = ngx.req.start_time() + maxAge
    local session_key = cache:get("session_"..user)
    if not session_key then
        session_key = random_string()
        cache:add("session_"..user, session_key, conf["session_max_timeout"])
    end
    local hash = hmac_sha512(srvkey,
               user..
               "|"..expire..
               "|"..session_key)
    local cookie_str = "; Domain=."..domain..
                       "; Path=/"..
                       "; Expires="..ngx.cookie_time(expire)..
                       "; Secure"..
                       "; HttpOnly"..
                       "; SameSite=Lax"

    ngx.header["Set-Cookie"] = {
        "SSOwAuthUser="..user..cookie_str,
        "SSOwAuthHash="..hash..cookie_str,
        "SSOwAuthExpire="..expire..cookie_str
    }
    logger.info("Hash "..hash.." generated for "..user.."@"..ngx.var.remote_addr)
end


-- Expires the 3 session cookies
function delete_cookie()
    for _, domain in ipairs(conf["domains"]) do
        local cookie_str = "; Domain=."..domain..
                           "; Path=/"..
                           "; Expires="..ngx.cookie_time(0)..
                           "; Secure"..
                           "; HttpOnly"..
                           "; SameSite=Lax"
        ngx.header["Set-Cookie"] = {
            "SSOwAuthUser="..cookie_str,
            "SSOwAuthHash="..cookie_str,
            "SSOwAuthExpire="..cookie_str
        }
    end
end


-- Validate authentification
--
-- Check if the session cookies are set, and rehash server + client information
-- to match the session hash.
--
function refresh_logged_in()
    local expireTime = ngx.var.cookie_SSOwAuthExpire
    local user = ngx.var.cookie_SSOwAuthUser
    local authHash = ngx.var.cookie_SSOwAuthHash

    authUser = nil
    is_logged_in = false

    if expireTime and expireTime ~= ""
    and authHash and authHash ~= ""
    and user and user ~= ""
    then
        -- Check expire time
        if (ngx.req.start_time() <= tonumber(expireTime)) then
            -- Check hash
            local session_key = cache:get("session_"..user)
            if session_key and session_key ~= "" then
                -- Check cache
                if cache:get(user.."-password") then
                    local hash = hmac_sha512(srvkey,
                            user..
                            "|"..expireTime..
                            "|"..session_key)
                    is_logged_in = hash == authHash
                    if is_logged_in then
                        authUser = user
                        return true
                    else
                        failReason = "Hash not matching"
                    end
                else
                    failReason = "No {user}-password entry in cache"
                end
            else
                failReason = "No session key"
            end
        else
            failReason = "Cookie expired"
        end
        logger.debug("SSOwat cookies rejected for "..user.."@"..ngx.var.remote_addr.." : "..failReason)
        return false
    end

    -- If client set the `Proxy-Authorization` header before reaching the SSO,
    -- we want to match user and password against the user database.
    --
    -- It allows to bypass the cookie-based procedure with a per-request
    -- authentication. This is useful to authenticate on the SSO during
    -- curl requests for example.

    local auth_header = ngx.req.get_headers()["Proxy-Authorization"]

    if auth_header then
        _, _, b64_cred = string.find(auth_header, "^Basic%s+(.+)$")
        if b64_cred == nil then
            return is_logged_in
        end
        _, _, user, password = string.find(ngx.decode_base64(b64_cred), "^(.+):(.+)$")
        user = authenticate(user, password)
        if user then
            logger.debug("User got authenticated through basic auth")
            authUser = user
            is_logged_in = true
        else
            -- https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/407
            ngx.status = 407
        end
    end

    return is_logged_in
end

-- Check whether a user is allowed to access a URL using the `permissions` directive
-- of the configuration file
function has_access(permission, user)
    user = user or authUser

    if permission == nil then
        logger.debug("No permission matching request for "..ngx.var.uri)
        return false
    end

    -- Public access
    if user == nil or permission["public"] then
        user = user or "A visitor"
        logger.debug(user.." tries to access "..ngx.var.uri.." (corresponding perm: "..permission["id"]..")")
        return permission["public"]
    end

    logger.debug("User "..user.." tries to access "..ngx.var.uri.." (corresponding perm: "..permission["id"]..")")

    -- The user has permission to access the content if he is in the list of allowed users
    if element_is_in_table(user, permission["users"]) then
        logger.debug("User "..user.." can access "..ngx.var.host..ngx.var.uri..uri_args_string())
        return true
    else
        logger.debug("User "..user.." cannot access "..ngx.var.uri)
        return false
    end
end

function element_is_in_table(element, table)
    if table then
        for _, el in pairs(table) do
            if el == element then
                return true
            end
        end
    end

    return false
end

-- Authenticate a user against the LDAP database using a username or an email
-- address.
-- Reminder: conf["ldap_identifier"] is "uid" by default
function authenticate(user, password)
    -- Try to find the username from an email address by openning an anonymous
    -- LDAP connection and check if the email address exists
    if conf["allow_mail_authentication"] and string.find(user, "@") then
        ldap = lualdap.open_simple(conf["ldap_host"])
        for dn, attribs in ldap:search {
            base = conf["ldap_group"],
            scope = "onelevel",
            sizelimit = 1,
            filter = "(mail="..user..")",
            attrs = {conf["ldap_identifier"]}
        } do
            if attribs[conf["ldap_identifier"]] then
                logger.debug("Use email: "..user)
                user = attribs[conf["ldap_identifier"]]
            else
                logger.error("Unknown email: "..user)
                return false
            end
        end
        ldap:close()
    end

    -- Now that we have a username, we can try connecting to the LDAP base.
    connected = lualdap.open_simple (
        conf["ldap_host"],
        conf["ldap_identifier"].."=".. user ..","..conf["ldap_group"],
        password
    )

    cache:flush_expired()

    -- If we are connected, we can retrieve the password and put it in the
    -- cache shared table in order to eventually reuse it later when updating
    -- profile information or just passing credentials to an application.
    if connected then
        if conf['ldap_enforce_crypt'] then
            ensure_user_password_uses_strong_hash(connected, user, password)
        end
        cache:add(user.."-password", password, conf["session_timeout"])
        ngx.log(ngx.NOTICE, "Connected as: "..user)
        logger.info("User "..user.." successfully authenticated from "..ngx.var.remote_addr)
        return user

    -- Else, the username/email or the password is wrong
    else
        -- N.B. : the ngx.log is important and is related to the regex used by
        -- the fail2ban rule to detect (and ban) failed login attempts
        ngx.log(ngx.ERR, "Connection failed for: "..user)
        logger.error("Authentication failure for user "..user.." from "..ngx.var.remote_addr)
        return false
    end
end

function delete_user_info_cache(user)
    cache:delete(user.."-"..conf["ldap_identifier"])
    local i = 2
    while cache:get(user.."-mail|"..i) do
        cache:delete(user.."-mail|"..i)
        i = i + 1
    end
    local i = 2
    while cache:get(user.."-maildrop|"..i) do
        cache:delete(user.."-maildrop|"..i)
        i = i + 1
    end
end

-- Set the authentication headers in order to pass credentials to the
-- application underneath.
function set_headers(user)
    local user = user or authUser
    -- Set `Authorization` header to enable HTTP authentification
    ngx.req.set_header("Authorization", "Basic "..ngx.encode_base64(
      user..":"..cache:get(user.."-password")
    ))

    -- Set optionnal additional headers (typically to pass email address)
    for k, v in pairs(conf["additional_headers"]) do
        ngx.req.set_header(k, cache:get(user.."-"..v))
    end

end


function refresh_user_cache(user)
    -- We definitely don't want to pass credentials on a non-encrypted
    -- connection.
    if ngx.var.scheme ~= "https" then
        return redirect("https://"..ngx.var.host..ngx.var.uri..uri_args_string())
    end

    local user = user or authUser

    -- If the password is not in cache or if the cache has expired, ask for
    -- logging.
    if not cache:get(user.."-password") then
        flash("info", t("please_login"))
        local back_url = ngx.var.scheme .. "://" .. ngx.var.host .. ngx.var.uri .. uri_args_string()
        return redirect(conf.portal_url.."?r="..ngx.encode_base64(back_url))
    end

    -- If the user information is not in cache, open an LDAP connection and
    -- fetch it.
    if not cache:get(user.."-"..conf["ldap_identifier"]) then
        ldap = lualdap.open_simple(
            conf["ldap_host"],
            conf["ldap_identifier"].."=".. user ..","..conf["ldap_group"],
            cache:get(user.."-password")
        )
        -- If the ldap connection fail (because the password was changed).
        -- Logout the user and invalid the password
        if not ldap then
            logger.debug("LDAP connection failed. Disconnect user : ".. user)
            cache:delete(authUser.."-password")
            flash("info", t("please_login"))
            local back_url = ngx.var.scheme .. "://" .. ngx.var.host .. ngx.var.uri .. uri_args_string()
            return redirect(conf.portal_url.."?r="..ngx.encode_base64(back_url))
        end
        logger.debug("Reloading LDAP values for: "..user)
        for dn, attribs in ldap:search {
            base = conf["ldap_identifier"].."=".. user ..","..conf["ldap_group"],
            scope = "base",
            sizelimit = 1,
            attrs = conf["ldap_attributes"]
        } do
            for k,v in pairs(attribs) do
                if type(v) == "table" then
                    for k2,v2 in ipairs(v) do
                        if k2 == 1 then cache:set(user.."-"..k, v2, conf["session_timeout"]) end
                        cache:set(user.."-"..k.."|"..k2, v2, conf["session_max_timeout"])
                    end
                else
                    cache:set(user.."-"..k, v, conf["session_timeout"])
                end
            end
        end
    else
        -- Else, just revalidate session for another day by default
        password = cache:get(user.."-password")
        -- Here we don't use set method to avoid strange logout
        -- See https://github.com/YunoHost/issues/issues/1830
        cache:replace(user.."-password", password, conf["session_timeout"])
    end
end


-- Summarize email, aliases and forwards in a table for a specific user
function get_mails(user)
    local mails = { mail = "", mailalias = {}, maildrop = {} }

    -- default mail
    mails["mail"] = cache:get(user.."-mail")

    -- mail aliases
    if cache:get(user.."-mail|2") then
        local i = 2
        while cache:get(user.."-mail|"..i) do
            table.insert(mails["mailalias"], cache:get(user.."-mail|"..i))
            i = i + 1
        end
    end

    -- mail forward
    if cache:get(user.."-maildrop|2") then
        local i = 2
        while cache:get(user.."-maildrop|"..i) do
            table.insert(mails["maildrop"], cache:get(user.."-maildrop|"..i))
            i = i + 1
        end
    end
    return mails
end


-- Yo dawg, this enables SSOwat to serve files in HTTP in an HTTP server
-- Much reliable, very solid.
--
-- Takes an URI, and returns file content with the proper HTTP headers.
-- It is used to render the SSOwat portal *only*.
function serve(uri, cache)

    logger.debug("Serving portal uri "..uri)

    rel_path = string.gsub(uri, conf["portal_path"], "/")

    -- Load login.html as index
    if rel_path == "/" then
        if is_logged_in then
            rel_path = "/portal.html"
        else
            rel_path = "/login.html"
        end
    end

    -- Access to directory root: forbidden
    if string.ends(rel_path, "/") then
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    -- Try to get file content
    local content = read_file(script_path.."portal"..rel_path)
    if not content then
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end

    -- Extract file extension
    _, file, ext = string.match(rel_path, "(.-)([^\\/]-%.?([^%.\\/]*))$")

    -- Associate to MIME type
    mime_types = {
        html = "text/html",
        ms   = "text/html",
        js   = "text/javascript",
        map  = "text/javascript",
        css  = "text/css",
        gif  = "image/gif",
        jpg  = "image/jpeg",
        png  = "image/png",
        svg  = "image/svg+xml",
        ico  = "image/vnd.microsoft.icon",
        woff = "font/woff",
        woff2 = "font/woff2",
        ttf = "font/ttf",
        json = "application/json"
    }

    -- Allow .ms to specify mime type
    mime = ext
    if ext == "ms" then
        subext = string.match(file, "^.+%.(.+)%.ms$")
        if subext then
            mime = subext
        end
    end

    -- Set Content-Type
    if mime_types[mime] then
        ngx.header["Content-Type"] = mime_types[mime]
    else
        ngx.header["Content-Type"] = "text/plain"
    end

    -- Render as mustache
    if ext == "html" then
        local data = get_data_for(file)
        local rendered = lustache:render(read_file(script_path.."portal/header.ms"), data)
        rendered = rendered..lustache:render(content, data)
        content = rendered..lustache:render(read_file(script_path.."portal/footer.ms"), data)
    elseif ext == "ms" then
        local data = get_data_for(file)
        content = lustache:render(content, data)
    elseif uri == "/ynh_userinfo.json" then
        local data = get_data_for(file)
        content = json.encode(data)
        cache = "dynamic"
    end

    -- Reset flash messages
    flashs["fail"] = nil
    flashs["win"] = nil
    flashs["info"] = nil

    if cache == "static_asset" then
        ngx.header["Cache-Control"] = "public, max-age=3600"
    else
        -- Ain't nobody got time for cache
        ngx.header["Cache-Control"] = "no-cache"
    end

    -- Print file content
    ngx.say(content)

    -- Return 200 :-)
    return ngx.exit(ngx.HTTP_OK)
end


-- Simple controller that computes a data table to populate a specific view.
-- The resulting data table typically contains the user information, the page
-- title, the flash notifications' content and the translated strings.
function get_data_for(view)
    local user = authUser

    -- For the login page we only need the page title
    if view == "login.html" then
        data = {
            title = t("login"),
            connected = false
        }

    -- For those views, we may need user information
    elseif view == "portal.html"
        or view == "edit.html"
        or view == "password.html"
        or view == "ynh_userinfo.json" then

        -- Invalidate cache before loading these views.
        -- Needed if the LDAP db is changed outside ssowat (from the cli for example).
        -- Not doing it for ynhpanel.json only for performance reasons,
        --   so the panel could show wrong first name, last name or main email address
        -- TODO: What if we remove info during logout?
        --if view ~= "ynhpanel.json" then
        --    delete_user_info_cache(user)
        --end

        -- Be sure cache is loaded
        if user then
            refresh_user_cache(user)

            local mails = get_mails(user)
            data = {
                connected  = true,
                theme      = conf.theme,
                portal_url = conf.portal_url,
                uid        = user,
                cn         = cache:get(user.."-cn"),
                sn         = cache:get(user.."-sn"),
                givenName  = cache:get(user.."-givenName"),
                mail       = mails["mail"],
                mailalias  = mails["mailalias"],
                maildrop   = mails["maildrop"],
                app = {}
            }

            local sorted_apps = {}

            -- Add user's accessible URLs using the ACLs.
            -- It is typically used to build the app list.
            for permission_name, permission in pairs(conf["permissions"]) do
                -- We want to display a tile, and uris is not empty
                if permission['show_tile'] and next(permission['uris']) ~= nil and element_is_in_table(user, permission["users"]) then
                    url = permission['uris'][1]
                    name = permission['label']

                    if ngx.var.host == conf["local_portal_domain"] then
                        url = string.gsub(url, conf["original_portal_domain"], conf["local_portal_domain"])
                    end

                    table.insert(sorted_apps, name)
                    table.sort(sorted_apps)
                    table.insert(data["app"], index_of(sorted_apps, name), { url = url, name = name })
                end
            end
        end
    end

    -- Pass all the translated strings to the view (to use with t_<key>)
    for k, v in pairs(i18n[conf["default_language"]]) do
        data["t_"..k] = (i18n[conf.lang] and i18n[conf.lang][k]) or v
    end

    -- Pass flash notification content
    data['flash_fail'] = {flashs["fail"]}
    data['flash_win']  = {flashs["win"] }
    data['flash_info'] = {flashs["info"]}
    data['theme'] = conf["theme"]

    return data
end

-- this function is launched after a successful login
-- it checked if the user password is stored using the most secure hashing
-- algorithm available
-- if it's not the case, it migrates the password to this new hash algorithm
function ensure_user_password_uses_strong_hash(ldap, user, password)
    local current_hashed_password = nil

    for dn, attrs in ldap:search {
        base = conf['ldap_group'],
        scope = "onelevel",
        sizelimit = 1,
        filter = "("..conf['ldap_identifier'].."="..user..")",
        attrs = {"userPassword"}
    } do
        current_hashed_password = attrs["userPassword"]:sub(0, 10)
    end

    -- if the password is not hashed using sha-512, which is the strongest
    -- available hash rehash it using that
    -- Here "{CRYPT}" means "uses linux auth system"
    -- "6" means "uses sha-512", any lower number mean a less strong algo (1 == md5)
    if current_hashed_password:sub(0, 10) ~= "{CRYPT}$6$" then
        local dn = conf["ldap_identifier"].."="..user..","..conf["ldap_group"]
        local hashed_password = hash_password(password)
        ldap:modify(dn, {'=', userPassword = hashed_password })
    end
end

-- Read result of a command after given it securely the password
function secure_cmd_password(cmd, password, start)
    -- Check password validity
    local tmp_file = os.tmpname()
    local w_pwd = io.popen("("..cmd..") | tee -a "..tmp_file, 'w')
    w_pwd:write(password)
    -- This second write is just to validate the password question
    -- Do not remove
    w_pwd:write("")
    w_pwd:close()
    local r_pwd = io.open(tmp_file, 'r')
    text = r_pwd:read "*a"

    -- Remove the extra end line
    if text:sub(-1, -1) == "\n" then
        text = text:sub(1, -2)
    end
    r_pwd:close()
    os.remove(tmp_file)
    return text
end

-- Compute the user modification POST request
-- It has to update cached information and edit the LDAP user entry
-- according to the changes detected.
function edit_user()
    -- We need these calls since we are in a POST request
    ngx.req.read_body()
    local args = ngx.req.get_post_args()

    -- Ensure that user is logged in and has passed information
    -- before continuing.
    if is_logged_in and args
    then

        -- Set HTTP status to 201
        ngx.status = ngx.HTTP_CREATED
        local user = authUser

        -- In case of a password modification
        -- TODO: split this into a new function
        if string.ends(ngx.var.uri, "password.html") then

            -- Check current password against the cached one
            if args.currentpassword
            and args.currentpassword == cache:get(user.."-password")
            then
                -- and the new password against the confirmation field's content
                if args.newpassword == args.confirm then
                    -- Check password validity
                    local result_msg = secure_cmd_password("python3 /usr/lib/python3/dist-packages/yunohost/utils/password.py", args.newpassword)
                    validation_error = true
                    if result_msg == nil or result_msg == "" then
                        validation_error = nil
                    end
                    if validation_error == nil then

                        local dn = conf["ldap_identifier"].."="..user..","..conf["ldap_group"]

                        -- Open the LDAP connection
                        local ldap = lualdap.open_simple(conf["ldap_host"], dn, args.currentpassword)

                        local password = hash_password(args.newpassword)

                        -- Modify the LDAP information
                        if ldap:modify(dn, {'=', userPassword = password }) then
                            if validation == nil then
                                flash("win", t("password_changed"))
                            else
                                flash("win", t(result_msg))
                            end

                            -- Reset the password cache
                            cache:set(user.."-password", args.newpassword, conf["session_timeout"])
                            return redirect(conf.portal_url.."portal.html")
                        else
                            flash("fail", t("password_changed_error"))
                        end
                    else
                        flash("fail", t(result_msg))
                    end
                else
                    flash("fail", t("password_not_match"))
                end
             else
                flash("fail", t("wrong_current_password"))
             end
             return redirect(conf.portal_url.."password.html")


         -- In case of profile modification
         -- TODO: split this into a new function
         elseif string.ends(ngx.var.uri, "edit.html") then

             -- Check that needed arguments exist
             if args.givenName and args.sn and args.mail then

                 -- Unstack mailaliases
                 local mailalias = {}
                 if args["mailalias[]"] then
                     if type(args["mailalias[]"]) == "string" then
                         args["mailalias[]"] = {args["mailalias[]"]}
                     end
                     mailalias = args["mailalias[]"]
                 end

                 -- Unstack mail forwards
                 local maildrop = {}
                 if args["maildrop[]"] then
                     if type(args["maildrop[]"]) == "string" then
                         args["maildrop[]"] = {args["maildrop[]"]}
                     end
                     maildrop = args["maildrop[]"]
                 end

                 -- Limit domains per user:
                 -- This ensures that a user already has an email address or an
                 -- aliases that ends with a specific domain to claim new aliases
                 -- on this domain.
                 --
                 -- I.E. You need to have xxx@domain.org to claim a
                 --      yyy@domain.org alias.
                 --
                 local domains = {}
                 local ldap = lualdap.open_simple(conf["ldap_host"])
                 for dn, attribs in ldap:search {
                     base = conf["ldap_group"],
                     scope = "onelevel",
                     sizelimit = 1,
                     filter = "(uid="..user..")",
                     attrs = {"mail"}
                 } do
                     -- Construct proper emails array
                     local mail_list = {}
                     local mail_attr = attribs["mail"]
                     if type(mail_attr) == "string" then
                         mail_list = { mail_attr }
                     elseif type(mail_attr) == "table" then
                         mail_list = mail_attr
                     end

                     -- Filter configuration's domain list to keep only
                     -- "allowed" domains
                     for _, domain in ipairs(conf["domains"]) do
                         for k, mail in ipairs(mail_list) do
                             if string.ends(mail, "@"..domain) then
                                 if not is_in_table(domains, domain) then
                                     table.insert(domains, domain)
                                 end
                             end
                         end
                     end
                 end
                 ldap:close()

                 local rex = require "rex_pcre"
                 local rex_flags = rex.flags()
                 local mail_re = rex.new([[^[\w\.\-+%]+@([^\W_A-Z]+([\-]*[^\W_A-Z]+)*\.)+([^\W\d_]{2,})$]], rex_flags.UTF8 + rex_flags.UCP)

                 local mails = {}

                 -- Build an LDAP filter so that we can ensure that email
                 -- addresses are used only once.
                 local filter = "(|"
                 table.insert(mailalias, 1, args.mail)

                 -- Loop through all the aliases
                 for k, mail in ipairs(mailalias) do
                     if mail ~= "" then
                         -- Check the mail pattern
                         if not mail_re:match(mail) then
                             flash("fail", t("invalid_mail")..": "..mail)
                             return redirect(conf.portal_url.."edit.html")

                         -- Check that the domain is known and allowed
                         else
                             local domain_valid = false
                             for _, domain in ipairs(domains) do
                                 if string.ends(mail, "@"..domain) then
                                     domain_valid = true
                                     break
                                 end
                             end
                             if domain_valid then
                                 table.insert(mails, mail)
                                 filter = filter.."(mail="..mail..")"
                             else
                                 flash("fail", t("invalid_domain").." "..mail)
                                 return redirect(conf.portal_url.."edit.html")
                             end
                         end
                     end
                 end

                 -- filter should look like "(|(mail=my@mail.tld)(mail=my@mail2.tld))"
                 filter = filter..")"


                 -- For email forwards, we only need to check that they look
                 -- like actual emails
                 local drops = {}
                 for k, mail in ipairs(maildrop) do
                     if mail ~= "" then
                         if not mail_re:match(mail) then
                             flash("fail", t("invalid_mailforward")..": "..mail)
                             return redirect(conf.portal_url.."edit.html")
                         end
                         table.insert(drops, mail)
                     end
                 end
                 table.insert(drops, 1, user)


                 -- We now have a list of validated emails and forwards.
                 -- We need to check if there is a user with a claimed email
                 -- already before writing modifications to the LDAP.
                 local dn = conf["ldap_identifier"].."="..user..","..conf["ldap_group"]
                 local ldap = lualdap.open_simple(conf["ldap_host"], dn, cache:get(user.."-password"))
                 local cn = args.givenName.." "..args.sn

                 for dn, attribs in ldap:search {
                     base = conf["ldap_group"],
                     scope = "onelevel",
                     filter = filter,
                     attrs = {conf["ldap_identifier"], "mail"}
                 } do
                     -- Another user with one of these emails has been found.
                     if attribs[conf["ldap_identifier"]] and attribs[conf["ldap_identifier"]] ~= user then
                         -- Construct proper emails array
                         local mail_list = {}
                         local mail_attr = attribs["mail"]
                         if type(mail_attr) == "string" then
                             mail_list = { mail_attr }
                         elseif type(mail_attr) == "table" then
                             mail_list = mail_attr
                         end

                         for _, mail in ipairs(mail_list) do
                             if is_in_table(mails, mail) then
                                 flash("fail", t("mail_already_used").." "..mail)
                             end
                         end
                         return redirect(conf.portal_url.."edit.html")
                     end
                 end

                 -- No problem so far, we can write modifications to the LDAP
                 if ldap:modify(dn, {'=', cn = cn,
                                          displayName = cn,
                                          givenName = args.givenName,
                                          sn = args.sn,
                                          mail = mails,
                                          maildrop = drops })
                 then
                     delete_user_info_cache(user)
                     -- Ugly trick to force cache reloading
                     refresh_user_cache(user)
                     flash("win", t("information_updated"))
                     return redirect(conf.portal_url.."portal.html")

                 else
                     flash("fail", t("user_saving_fail"))
                 end
             else
                 flash("fail", t("missing_required_fields"))
             end
             return redirect(conf.portal_url.."edit.html")
         end
    end
end

-- hash the user password using sha-512 and using {CRYPT} to uses linux auth system
-- because ldap doesn't support anything stronger than sha1
function hash_password(password)
    local hashed_password = secure_cmd_password("mkpasswd --method=sha-512", password)
    hashed_password = "{CRYPT}"..hashed_password
    return hashed_password
end

-- Compute the user login POST request
-- It authenticates the user against the LDAP base then redirects to the portal
function login()

    -- We need these calls since we are in a POST request
    ngx.req.read_body()
    local args = ngx.req.get_post_args()
    local uri_args = ngx.req.get_uri_args()

    args.user = string.lower(args.user)

    local user = authenticate(args.user, args.password)
    if user then
        ngx.status = ngx.HTTP_CREATED
        set_auth_cookie(user, ngx.var.host)
    else
        ngx.status = ngx.HTTP_UNAUTHORIZED
        flash("fail", t("wrong_username_password"))
    end

    -- Forward the `r` URI argument if it exists to redirect
    -- the user properly after a successful login.
    if uri_args.r then
        return redirect(conf.portal_url.."?r="..uri_args.r)
    else
        return redirect(conf.portal_url)
    end
end


-- Compute the user logout request
-- It deletes session cached information to invalidate client side cookie
-- information.
function logout()

    -- We need this call since we are in a POST request
    local args = ngx.req.get_uri_args()

    -- Delete user cookie if logged in (that should always be the case)
    if is_logged_in then
        delete_cookie()
        cache:delete("session_"..authUser)
        cache:delete(authUser.."-"..conf["ldap_identifier"]) -- Ugly trick to reload cache
        cache:delete(authUser.."-password")
        delete_user_info_cache(authUser)
        flash("info", t("logged_out"))
        is_logged_in = false
    end

    -- Redirect with the `r` URI argument if it exists or redirect to portal
    if args.r then
        return redirect(ngx.decode_base64(args.r))
    else
        return redirect(conf.portal_url)
    end
end


-- Set cookie and redirect (needed to properly set cookie)
function redirect(url)
    logger.debug("Redirecting to "..url)
    -- For security reason we don't allow to redirect onto unknown domain
    -- And if `uri_args.r` contains line break, someone is probably trying to
    -- pass some additional headers

    -- This should cover the following cases:
    -- https://malicious.domain.tld/foo/bar
    -- http://malicious.domain.tld/foo/bar
    -- https://malicious.domain.tld:1234/foo
    -- malicious.domain.tld/foo/bar
    -- (/foo/bar, in which case no need to make sure it's prefixed with https://)
    if not string.starts(url, "/") and not string.starts(url, "http://") and not string.starts(url, "https://") then
        url = "https://"..url
    end
    local is_known_domain = string.starts(url, "/")
    for _, domain in ipairs(conf["domains"]) do
        if is_known_domain then
          break
        end
        -- Replace - character to %- because - is a special char for regex in lua
        domain = string.gsub(domain, "%-","%%-")
        is_known_domain = is_known_domain or url:match("^https?://"..domain.."/?") ~= nil
    end
    if string.match(url, "(.*)\n") or not is_known_domain then
        logger.debug("Unauthorized redirection to "..url)
        flash("fail", t("redirection_error_invalid_url"))
        url = conf.portal_url
    end
    return ngx.redirect(url)
end


-- Set cookie and go on with the response (needed to properly set cookie)
function pass()
    logger.debug("Allowing to pass through "..ngx.var.uri)

    -- When we are in the SSOwat portal, we need a default `content-type`
    if string.ends(ngx.var.uri, "/")
    or string.ends(ngx.var.uri, ".html")
    or string.ends(ngx.var.uri, ".htm")
    then
        ngx.header["Content-Type"] = "text/html"
    end

    return
end
