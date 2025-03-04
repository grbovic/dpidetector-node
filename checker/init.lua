-- luacheck: globals

local interval = 600

local json   = require"cjson"
local utils  = require"checker.utils"
local req    = require"checker.requests"
local custom = require"checker.custom"
local sleep  = utils.sleep
local getenv = utils.getenv
local log    = utils.logger

_G.proto    = custom.proto
_G.token    = getenv"token"
_G.nodename = getenv"node"

_G.DEBUG   = os.getenv"DEBUG"   or os.getenv(("%s_DEBUG"):format(_G.proto:gsub("-", "_")))
_G.VERBOSE = os.getenv"VERBOSE" or os.getenv(("%s_VERBOSE"):format(_G.proto:gsub("-", "_")))

if _G.VERBOSE or _G.DEBUG then
  _G.stdout = io.stdout
  _G.stderr = io.stderr
else
  _G.devnull = io.output("/dev/null")
  _G.stdout  = _G.devnull
  _G.stderr  = _G.devnull
end

log.verbose"=== Запуск приложения ==="

if custom.init then
  log.verbose"=== Запуск функции инициализации, специфичной для протокола ==="
  local ok, ret = pcall(custom.init)
  if not ok then
    log.debug(("Ошибка при инициализации: %q"):format(ret))
    os.exit(1)
  end
  log.verbose"=== Инициализация завершена успешно ==="
end

local backend_domain = "dpidetect.org"
local api = ("https://%s/api"):format(backend_domain)
local servers_endpoint = ("%s/servers/"):format(api)
local reports_endpoint = ("%s/reports/"):format(api)

log.verbose"=== Вход в основной рабочий цикл ==="
while true do
  log.verbose"=== Итерация главного цикла начата ==="
  local servers = {}

  local geo = req{
    url = "https://geo.dpidetect.org/get-iso/plain"
  }

  if geo:match"RU" then
    -- Выполнять проверки только если нода выходит в интернет в России (например, не через VPN)
    -- т.к. в данный момент нас интересует именно блокировка трафика из/внутри России,
    -- а трафик из заграницы для этих целей бесполезен
    local headers = {
        ("Token: %s"):format(_G.token),
      }
    local servers_fetched = req{
      url = servers_endpoint,
      headers = headers,
    }

    if servers_fetched:match"COULDNT_CONNECT" then
      --- HACK: (костыль) если получили ошибку "невозможно соединиться",
      --- то на всякий случай попробуем перезапросить ещё раз
      servers_fetched = req{
        url = servers_endpoint,
        headers = headers,
      }
    end

    if servers_fetched
      and servers_fetched:match"name"
      and servers_fetched:match"^%["
    then
      local ok, e = pcall(json.decode, servers_fetched)
      if not ok then
        log.error"Проблема со списком серверов (при частом повторении - попробуйте включить режим отладки)"
        log.verbose"(Не получается десериализовать JSON со списком серверов)"
        log.verbose"====== Результат запроса: ======"
        log.verbose(servers_fetched)
        log.verbose"=================="
        log.verbose"====== Результат попытки десериализации: ======"
        log.verbose(e)
        log.verbose"=================="
      else
        servers = e
      end
    else
      log.error"Не удалось связаться с бекендом"
      log.error"Если данное сообщение имеет разовый характер - можно игнорировать"
      log.error"Если появляется при каждой итерации проверки - включите режим отладки и проверьте причину"
      log.verbose"====== Результат запроса: ======"
      log.verbose(servers_fetched)
      log.verbose"=================="
    end
  end

  for _, server in ipairs(servers) do
    log.verbose"=== Итерация цикла проверки серверов начата ==="
    local conn = custom.connect(server)
    if conn then
      log.verbose"=== Функция установки соединения завершилась успешно ==="
      log.verbose"=== Запуск функции проверки доступности ==="
      local result = custom.checker and custom.checker(server) or false
      log.verbose"=== Запуск функции завершения соединения ==="
      custom.disconnect(server)
      local available = not(not(result))

      local report = {
        server_name = tostring(server.name),
        protocol = tostring(_G.proto),
        available = available,
        node_name = tostring(_G.nodename),
        -- log = log_fd:read"*a" -- :lines() --- TODO:
      }

      log.verbose"=== Отправка отчёта ==="
      log.verbose(("=== (%sблокируется) ==="):format(available and "не " or ""))
      req{
        url = reports_endpoint,
        post = json.encode(report),
        headers = {
          ("Token: %s"):format(_G.token),
          "Content-Type: application/json",
        },
      }
    end
    log.verbose"=== Итерация цикла проверки серверов завершена ==="
  end
  log.verbose"=== Итерация главного цикла начата ==="
  log.verbose(("=== Ожидание следующей итерации цикла проверки (%d секунд) ==="):format(interval))
  sleep(interval)
end
