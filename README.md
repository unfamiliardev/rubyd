# rubyd

`rubyd` is a from-scratch Ruby HTTP server project designed for systems-style experimentation.
It uses low-level sockets (`TCPServer`, `IO.select`), a thread-pool worker model, a Ruby DSL config,
a plugin system, and a built-in benchmark client.

## Features

- Evented accept loop with `IO.select`
- Thread-pool request workers for concurrent clients
- CLI lifecycle management: `start`, `stop`, `restart`, `reload`, `status`
- PID file management via `rubyd.pid`
- Signal handling (`SIGINT`, `SIGTERM`, `SIGHUP` when supported)
- Ruby DSL configuration (`config.rb`)
- Plugin hooks (`before_request`, `after_response`) + route registration
- Access and error logging to files with rotation
- Built-in load tool: `rubyd bench`
- Automatic default website in `www/index.html`
- Keep-alive, graceful connection draining, and request middleware pipeline
- TLS listener support via Ruby OpenSSL
- WebSocket handshake + text echo loop
- Virtual hosts (host header to root mapping)
- Reverse proxy rules
- Rate limiting + IP allow/block lists + optional basic auth
- Caching (`ETag`, `Last-Modified`, `Cache-Control`) + range requests
- Compression (`gzip`, optional `br` when `brotli` gem is present)
- Upload endpoint (`/upload`) with multipart handling
- Metrics endpoint (`/metrics`)
- Directory listing + custom error pages (`www/errors/*.html`)
- Native `rubyd` template pages (`.rubyd`)

## Project Layout

```text
rubyd/
 ├── bin/rubyd
 ├── lib/rubyd/
 │   ├── server.rb
 │   ├── parser.rb
 │   ├── router.rb
 │   ├── config.rb
 │   ├── logger.rb
 │   ├── plugin.rb
 │   ├── cli.rb
 │   ├── bench.rb
 ├── plugins/
 ├── www/
 ├── logs/
 ├── rubyd.pid
 ├── config.rb
 ├── README.md
```

## Run

From the `rubyd` directory:

```bash
ruby bin/rubyd start
```

Then check status:

```bash
ruby bin/rubyd status
```

Stop server:

```bash
ruby bin/rubyd stop
```

## Commands

- `ruby bin/rubyd start` - start in background
- `ruby bin/rubyd stop` - stop gracefully (TERM)
- `ruby bin/rubyd restart` - stop + start
- `ruby bin/rubyd reload` - trigger config reload (`HUP`)
- `ruby bin/rubyd status` - process status from PID file
- `ruby bin/rubyd bench` - run benchmark against active server

### Benchmark examples

```bash
ruby bin/rubyd bench -n 10000 -c 50
ruby bin/rubyd bench -n 5000 -c 20 --path /echo
```

Example output:

```text
Requests: 10000
Concurrency: 50
Completed: 10000
Failed: 0
RPS: 3200.12
Avg Latency: 12.34ms
Max Latency: 38.91ms
```

## Configuration DSL (`config.rb`)

```ruby
port 9292
host "0.0.0.0"
root "www"
worker_threads 8

plugins do
  enable :echo
  # disable :echo
end
```

## Plugins

Plugins live in `plugins/*.rb` and should:

1. Subclass `Rubyd::Plugin::Base`
2. Optionally implement hooks:
   - `setup(router)`
   - `before_request(request)`
   - `after_response(request, response)`
3. Register with `Rubyd::Plugin.register(:name, PluginClass)`

See `plugins/echo.rb` for a working example.

## Dynamic Content

### PHP support (`.php`)

`rubyd` includes a built-in PHP-like runtime (no external `php-cgi` required).

Supported today in native mode:

- `<?php ... ?>` and `<?= ... ?>`
- `echo ...;`
- variable assignment (`$name = ...;`)
- `$_GET[...]`, `$_POST[...]`, and `$_SERVER[...]`
- null-coalescing (`??`), concatenation (`.`), and comparisons (`==`, `!=`, `>`, `<`, `>=`, `<=`)
- `header(...)`
- `gmdate(...)` and `htmlspecialchars(...)`
- `include`, `include_once`
- `if (...) { ... } else { ... }`
- `foreach (...) { ... }`
- `function name(...) { ... }` + `return`

Examples:

```bash
ruby bin/rubyd start
# then open http://127.0.0.1:9292/info.php?name=rubyd
```

### rubyd template language (`.rubyd`)

Files with `.rubyd` are rendered as HTML with simple placeholders:

- `{{method}}`
- `{{path}}`
- `{{query}}`
- `{{remote_addr}}`
- `{{time}}`

Example:

```bash
# open http://127.0.0.1:9292/example.rubyd?demo=1
```

## Built-in Endpoints

- `GET /health` basic health probe
- `GET /metrics` JSON runtime metrics
- `GET /upload` upload form
- `POST /upload` multipart upload target
