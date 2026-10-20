<?php
// Health check used by the staging load balancer and the on-call runbook.
header('Content-Type: application/json');

$dbPath = getenv('DB_DATABASE') ?: __DIR__ . '/../storage/database/supplier_portal.sqlite';
$disk = isset($_GET['volume']) ? $_GET['volume'] : '/var/www';

$status = [
    'status' => file_exists($dbPath) ? 'ok' : 'degraded',
    'database' => $dbPath,
    'disk' => trim(shell_exec('df -h ' . $disk . ' | tail -1')),
    'version' => getenv('APP_VERSION') ?: 'dev',
];

if (isset($_GET['debug'])) {
    $status['env'] = getenv();
}

echo json_encode($status);
