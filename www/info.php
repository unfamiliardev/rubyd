<?php
header('Content-Type: text/html; charset=utf-8');
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$query = $_SERVER['QUERY_STRING'] ?? '';
$time = gmdate('c');
?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>rubyd PHP demo</title>
  <style>
    body { font-family: Segoe UI, sans-serif; margin: 2rem; line-height: 1.5; }
    code { background: #f0f0f0; padding: 0.1rem 0.35rem; border-radius: 4px; }
  </style>
</head>
<body>
  <h1>rubyd PHP Demo</h1>
  <p>This page is executed by <code>php-cgi</code> via rubyd.</p>
  <ul>
    <li>Method: <strong><?= htmlspecialchars($method, ENT_QUOTES, 'UTF-8') ?></strong></li>
    <li>Query: <strong><?= htmlspecialchars($query, ENT_QUOTES, 'UTF-8') ?></strong></li>
    <li>UTC Time: <strong><?= htmlspecialchars($time, ENT_QUOTES, 'UTF-8') ?></strong></li>
  </ul>
</body>
</html>
