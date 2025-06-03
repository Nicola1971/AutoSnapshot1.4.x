//<?php
/**
 * AutoSnapshot 1.4.x
 *
 * Automatic database snapshot backup plugin for Evolution CMS 1.4.x
 *
 * @author    Nicola Lambathakis http://www.tattoocms.it/
 * @category    plugin
 * @version     1.3.2
 * @license	 http://www.gnu.org/copyleft/gpl.html GNU Public License (GPL)
 * @internal    @events OnManagerLogin,OnBeforeManagerLogout
 * @internal @properties &backupPath=Backup Path;string;assets/backup/ &keepBackups=Number of snapshots to keep;string;10 &backup_at=Run Backup at:;menu;Login,Logout,Both;Logout &allow_backup=Run Backup for:;menu;All,ThisRolesOnly,ThisUsersOnly;All &this_roles=Role IDs (comma separated):;string;1 &this_users=User IDs (comma separated):;string;1 &debugMode=Debug Mode;menu;false,true;false
 * @internal    @modx_category Admin
 */

// Prevent direct execution
if (!defined('MODX_BASE_PATH')) {
    die('Direct access to this file is not allowed.');
}

// Function to detect Evolution CMS version
function getEvolutionVersion() {
    global $modx;
    
    $version = '1.4.35'; // Default for Evolution 1.4.x
    $versionSources = [];
    
    // Method 1: From EVO configurations
    if (isset($modx) && is_object($modx)) {
        if (isset($modx->config['settings_version'])) {
            $version = $modx->config['settings_version'];
            $versionSources[] = "modx->config['settings_version']";
        } elseif (isset($modx->config['version'])) {
            $version = $modx->config['version'];
            $versionSources[] = "modx->config['version']";
        } elseif (method_exists($modx, 'getVersionData')) {
            $versionData = $modx->getVersionData();
            if (isset($versionData['version'])) {
                $version = $versionData['version'];
                $versionSources[] = "modx->getVersionData()";
            }
        }
    }
    
    // Method 2: From version file if it exists
    if (count($versionSources) === 0) {
        $versionFile = MODX_BASE_PATH . 'manager/includes/version.inc.php';
        if (file_exists($versionFile)) {
            $versionContent = file_get_contents($versionFile);
            // Search common patterns for version in Evolution 1.4.x
            if (preg_match('/\$modx_version\s*=\s*[\'"]([^\'"]+)[\'"]/', $versionContent, $matches)) {
                $version = $matches[1];
                $versionSources[] = "version.inc.php (\$modx_version)";
            } elseif (preg_match('/[\'"]version[\'"]\s*=>\s*[\'"]([^\'"]+)[\'"]/', $versionContent, $matches)) {
                $version = $matches[1];
                $versionSources[] = "version.inc.php (array)";
            } elseif (preg_match('/version[\'"]?\s*=>\s*[\'"]([^\'"]+)[\'"]/', $versionContent, $matches)) {
                $version = $matches[1];
                $versionSources[] = "version.inc.php (config)";
            }
        }
    }
    
    // Method 3: From database (system_settings table) - only if not found elsewhere
    if (count($versionSources) === 0) {
        try {
            global $database_server, $database_user, $database_password, $dbase, $table_prefix;
            
            if (!empty($database_server) && !empty($database_user) && !empty($dbase)) {
                $conn = new mysqli($database_server, $database_user, $database_password, trim($dbase, '`'));
                if (!$conn->connect_error) {
                    // Try different queries to find version
                    $versionQueries = [
                        "SELECT setting_value FROM {$table_prefix}system_settings WHERE setting_name = 'settings_version'",
                        "SELECT setting_value FROM {$table_prefix}system_settings WHERE setting_name = 'version'",
                        "SELECT setting_value FROM {$table_prefix}system_settings WHERE setting_name LIKE '%version%' LIMIT 1"
                    ];
                    
                    foreach ($versionQueries as $query) {
                        $result = $conn->query($query);
                        if ($result && $row = $result->fetch_assoc()) {
                            $dbVersion = trim($row['setting_value']);
                            if (!empty($dbVersion) && $dbVersion !== '0') {
                                $version = $dbVersion;
                                $versionSources[] = "database (system_settings)";
                                break;
                            }
                        }
                    }
                    $conn->close();
                }
            }
        } catch (Exception $e) {
            // Ignore errors, continue with other methods
        }
    }
    
    // If we haven't found anything, keep the default
    if (count($versionSources) === 0) {
        $versionSources[] = "default (Evolution 1.4.x detected)";
    }
    
    return [
        'version' => $version,
        'sources' => $versionSources
    ];
}

// Log function
function autoBackupLog($message, $debugMode = false) {
    if ($debugMode === 'true' || $debugMode === true) {
        $logFile = MODX_BASE_PATH . 'assets/backup_log_1x.txt';
        $timestamp = date('Y-m-d H:i:s');
        file_put_contents($logFile, "[{$timestamp}] {$message}" . PHP_EOL, FILE_APPEND);
    }
}

// Initial log
autoBackupLog("--- START AUTOSNAPSHOT 1.4.x ---", $debugMode);

// Detect Evolution CMS version
$versionInfo = getEvolutionVersion();
$evolutionVersion = $versionInfo['version'];
$versionSources = $versionInfo['sources'];

autoBackupLog("Evolution CMS version detected: {$evolutionVersion}", $debugMode);
autoBackupLog("Version sources: " . implode(', ', $versionSources), $debugMode);

// Supported events
$evtName = isset($modx->event->name) ? $modx->event->name : 'Unknown';
autoBackupLog("Event triggered: {$evtName}", $debugMode);

// Check if event is supported
$validEvents = ['OnManagerLogin', 'OnBeforeManagerLogout'];
if (!in_array($evtName, $validEvents)) {
    autoBackupLog("Unsupported event: {$evtName}", $debugMode);
    return;
}

// Check if backup should run for this specific event
$backup_at = isset($backup_at) ? $backup_at : 'Logout';
$should_backup = false;
switch ($backup_at) {
    case 'Login':
        $should_backup = ($evtName === 'OnManagerLogin');
        break;
    case 'Logout':
        $should_backup = ($evtName === 'OnBeforeManagerLogout');
        break;
    case 'Both':
        $should_backup = true; // For all supported events
        break;
}

if (!$should_backup) {
    autoBackupLog("Backup skipped: event {$evtName} not enabled (setting: {$backup_at})", $debugMode);
    return;
}

// Settings
$keepBackups = isset($keepBackups) && is_numeric($keepBackups) ? (int)$keepBackups : 10;
$backupPath = isset($backupPath) && !empty($backupPath) ? $backupPath : 'assets/backup/';
$backup_at = isset($backup_at) ? $backup_at : 'Logout';
$allow_backup = isset($allow_backup) ? $allow_backup : 'All';
$this_roles = isset($this_roles) ? trim($this_roles) : '1';
$this_users = isset($this_users) ? trim($this_users) : '1';

autoBackupLog("Settings: backupPath={$backupPath}, keepBackups={$keepBackups}, backup_at={$backup_at}, allow_backup={$allow_backup}", $debugMode);

// Check user restrictions
$run_backup = false;
$current_user = 0;
$current_role = 0;
$username = 'admin';

// Method 1: Use Evolution 1.4.x native APIs
if (method_exists($modx, 'getLoginUserID')) {
    $current_user = $modx->getLoginUserID();
    if ($current_user) {
        autoBackupLog("User found via API getLoginUserID: {$current_user}", $debugMode);
        
        // Use getUserInfo to get details
        $userInfo = $modx->getUserInfo($current_user);
        if ($userInfo && isset($userInfo['username'])) {
            $username = $userInfo['username'];
            $current_role = $userInfo['role'] ?? 0;
            autoBackupLog("Username from getUserInfo: {$username}, role: {$current_role}", $debugMode);
        }
    }
}

// Method 2: Fallback to sessions if API doesn't work
if (!$current_user && isset($_SESSION['mgrInternalKey']) && $_SESSION['mgrInternalKey'] > 0) {
    $current_user = $_SESSION['mgrInternalKey'];
    autoBackupLog("User found in session: {$current_user}", $debugMode);
    
    // Get user information from database if API didn't work
    try {
        $conn = new mysqli($database_server, $database_user, $database_password, trim($dbase, '`'));
        if (!$conn->connect_error) {
            // First check if table exists
            $table_check = $conn->query("SHOW TABLES LIKE '{$table_prefix}manager_users'");
            if ($table_check && $table_check->num_rows > 0) {
                $query = "SELECT username, role FROM {$table_prefix}manager_users WHERE id = " . intval($current_user);
                autoBackupLog("User query: {$query}", $debugMode);
                $result = $conn->query($query);
                
                if ($result && $row = $result->fetch_assoc()) {
                    $username = $row['username'];
                    $current_role = $row['role'];
                    autoBackupLog("Username retrieved from DB: {$username}, role: {$current_role}", $debugMode);
                } else {
                    autoBackupLog("No result from user query, using admin", $debugMode);
                    $username = "admin";
                }
            } else {
                autoBackupLog("Table {$table_prefix}manager_users does not exist, using admin", $debugMode);
                $username = "admin";
            }
            $conn->close();
        } else {
            autoBackupLog("Connection error for user info: {$conn->connect_error}", $debugMode);
            $username = "admin";
        }
    } catch (Exception $e) {
        autoBackupLog("Error retrieving user info: " . $e->getMessage(), $debugMode);
        $username = "admin";
    }
}

autoBackupLog("Current user: ID={$current_user}, Role={$current_role}, Username={$username}", $debugMode);

// Permission check
switch ($allow_backup) {
    case 'All':
        $run_backup = ($current_user > 0); // Only authenticated users
        break;
    case 'ThisRolesOnly':
        $allowed_roles = array_map('trim', explode(',', $this_roles));
        $run_backup = in_array($current_role, $allowed_roles);
        break;
    case 'ThisUsersOnly':
        $allowed_users = array_map('trim', explode(',', $this_users));
        $run_backup = in_array($current_user, $allowed_users);
        break;
}

if (!$run_backup) {
    autoBackupLog("Backup not executed: user {$current_user} with role {$current_role} not authorized", $debugMode);
    return;
}

// Ensure path is absolute
if (!preg_match('~^(/|\\\\|[a-zA-Z]:)~', $backupPath)) {
    $backupPath = MODX_BASE_PATH . $backupPath;
}

// Ensure it ends with a slash
$backupPath = rtrim($backupPath, '/\\') . '/';
autoBackupLog("Backup path: {$backupPath}", $debugMode);

// Create directory if it doesn't exist
if (!is_dir($backupPath)) {
    if (!mkdir($backupPath, 0755, true)) {
        autoBackupLog("ERROR: Unable to create directory {$backupPath}", $debugMode);
        return;
    }
}

// Check write permissions
if (!is_writable($backupPath)) {
    autoBackupLog("ERROR: Backup directory is not writable: {$backupPath}", $debugMode);
    return;
}

// Create .htaccess to protect backups
if (!file_exists($backupPath . ".htaccess")) {
    $htaccess = "order deny,allow\ndeny from all\n";
    file_put_contents($backupPath . ".htaccess", $htaccess);
}

// Create backup filename
$timestamp = date('Y-m-d_H-i-s');
$eventShort = str_replace(['On', 'Manager', 'Before', 'After'], '', $evtName);
$filename = "{$timestamp}_auto_snapshot_{$eventShort}_{$username}.sql";
$path = $backupPath . $filename;
autoBackupLog("Snapshot file: {$path}", $debugMode);

// Get database credentials
global $dbase, $database_server, $database_user, $database_password, $table_prefix;

// Remove backticks from database name
$database = trim($dbase, '`');
$host = $database_server;
$db_username = $database_user;
$password = $database_password;
$prefix = $table_prefix;

autoBackupLog("Correct DB credentials: database={$database}, host={$host}, username={$db_username}, prefix={$prefix}", $debugMode);

// Verify credentials
if (empty($database) || empty($db_username)) {
    autoBackupLog("ERROR: Missing database credentials", $debugMode);
    return;
}

// DATABASE BACKUP
$backupSuccess = false;

try {
    // Direct method with mysqli
    autoBackupLog("Attempting backup with mysqli", $debugMode);
    
    // Create database connection
    $mysqli = new mysqli($host, $db_username, $password, $database);
    
    if ($mysqli->connect_error) {
        autoBackupLog("MySQL connection error: {$mysqli->connect_error}", $debugMode);
        
        // Alternative attempt without specifying database in connection
        autoBackupLog("Attempting alternative connection...", $debugMode);
        $mysqli = new mysqli($host, $db_username, $password);
        
        if ($mysqli->connect_error) {
            autoBackupLog("MySQL connection error (alternative): {$mysqli->connect_error}", $debugMode);
        } else {
            // Select database after connection
            if (!$mysqli->select_db($database)) {
                autoBackupLog("Database selection error: {$mysqli->error}", $debugMode);
            } else {
                autoBackupLog("Alternative MySQL connection established", $debugMode);
                goto process_backup;
            }
        }
    } else {
        autoBackupLog("MySQL connection established", $debugMode);
        
        process_backup:
        
        // Get list of tables with specified prefix
        $tables = [];
        $sql = "SHOW TABLES LIKE '{$prefix}%'";
        autoBackupLog("Tables query: {$sql}", $debugMode);
        $result = $mysqli->query($sql);
        
        if ($result) {
            while ($row = $result->fetch_row()) {
                $tables[] = $row[0];
            }
        } else {
            autoBackupLog("SHOW TABLES query error: {$mysqli->error}", $debugMode);
        }
        
        autoBackupLog("Tables found: " . count($tables), $debugMode);
        if (count($tables) > 0) {
            autoBackupLog("First 3 tables: " . implode(", ", array_slice($tables, 0, 3)), $debugMode);
        }
        
        if (count($tables) > 0) {
            // SQL file header
            $siteName = isset($modx->config['site_name']) ? $modx->config['site_name'] : 'Evolution CMS Site';
            
            // Get server information
            $serverVersion = '';
            $phpVersion = phpversion();
            
            try {
                $serverResult = $mysqli->query("SELECT VERSION() as version");
                if ($serverResult && $row = $serverResult->fetch_assoc()) {
                    $serverVersion = $row['version'];
                }
            } catch (Exception $e) {
                $serverVersion = 'Unknown';
            }
            
            $output = "#\n";
            $output .= "# " . addslashes($siteName) . " Database Dump\n";
            $output .= "# MODX Version: {$evolutionVersion}\n";
            $output .= "# \n";
            $output .= "# Host: " . $host . "\n";
            $output .= "# Generation Time: " . date("d-m-Y H:i:s") . "\n";
            $output .= "# Server version: " . $serverVersion . "\n";
            $output .= "# PHP Version: " . $phpVersion . "\n";
            $output .= "# Database: `" . $database . "`\n";
            $output .= "# Description: Auto-snapshot triggered by {$username} via {$evtName}\n";
            $output .= "#\n\n";
            
            // Compatible MySQL settings
            $output .= "SET SQL_MODE=\"NO_AUTO_VALUE_ON_ZERO\";\n";
            $output .= "SET time_zone = \"+00:00\";\n\n";
            
            // Write header to file
            $headerWritten = file_put_contents($path, $output);
            autoBackupLog("Header written: {$headerWritten} bytes", $debugMode);
            
            // Loop through all tables
            $totalRows = 0;
            foreach ($tables as $table) {
                autoBackupLog("Processing table: {$table}", $debugMode);
                $output = "";
                
                // Get table structure
                $result = $mysqli->query("SHOW CREATE TABLE `{$table}`");
                if (!$result) {
                    autoBackupLog("ERROR in SHOW CREATE TABLE query: " . $mysqli->error, $debugMode);
                    continue;
                }
                
                $row = $result->fetch_row();
                $output .= "DROP TABLE IF EXISTS `{$table}`;\n";
                $output .= $row[1] . ";\n\n";
                
                // Write structure to file
                file_put_contents($path, $output, FILE_APPEND);
                $output = "";
                
                // Get table data
                $result = $mysqli->query("SELECT * FROM `{$table}`");
                if (!$result) {
                    autoBackupLog("ERROR in SELECT query: " . $mysqli->error, $debugMode);
                    continue;
                }
                
                $numRows = $result->num_rows;
                $totalRows += $numRows;
                
                if ($numRows > 0) {
                    autoBackupLog("Table {$table}: {$numRows} rows", $debugMode);
                    
                    // Process data row by row for compatibility
                    while ($row = $result->fetch_row()) {
                        $output = "INSERT INTO `{$table}` VALUES (";
                        
                        $values = [];
                        foreach ($row as $value) {
                            if ($value === null) {
                                $values[] = "NULL";
                            } else {
                                $values[] = "'" . $mysqli->real_escape_string($value) . "'";
                            }
                        }
                        
                        $output .= implode(", ", $values);
                        $output .= ");\n";
                        
                        // Write each row to file
                        file_put_contents($path, $output, FILE_APPEND);
                    }
                    
                    file_put_contents($path, "\n", FILE_APPEND);
                }
            }
            
            // Verify result
            if (file_exists($path)) {
                $filesize = filesize($path);
                autoBackupLog("Backup completed: {$filesize} bytes written, {$totalRows} total rows", $debugMode);
                $backupSuccess = ($filesize > 500 && $totalRows > 0); // More flexible check
            } else {
                autoBackupLog("ERROR: Backup file not created", $debugMode);
            }
        } else {
            autoBackupLog("ERROR: No tables found", $debugMode);
        }
        
        $mysqli->close();
    }
} catch (Exception $e) {
    autoBackupLog("ERROR in backup: " . $e->getMessage(), $debugMode);
}

// Final verification
if ($backupSuccess) {
    // Log to file when debug is active
    autoBackupLog("SUCCESS: AutoSnapshot completed: {$filename} (" . filesize($path) . " bytes) - Evolution CMS {$evolutionVersion}", $debugMode);
    
    // Clean old backups
    $pattern = $backupPath . "*_auto_snapshot_*.sql";
    $files = glob($pattern);
    
    if (is_array($files) && count($files) > $keepBackups) {
        autoBackupLog("Cleaning old backups (keeping last {$keepBackups})...", $debugMode);
        
        // Sort by date (oldest first)
        usort($files, function($a, $b) {
            return filemtime($a) - filemtime($b);
        });
        
        // Delete the oldest
        $deleteCount = count($files) - $keepBackups;
        for ($i = 0; $i < $deleteCount; $i++) {
            if (@unlink($files[$i])) {
                autoBackupLog("Backup deleted: " . basename($files[$i]), $debugMode);
            } else {
                autoBackupLog("ERROR: unable to delete " . basename($files[$i]), $debugMode);
            }
        }
    }
} else {
    // Log to file when debug is active
    autoBackupLog("ERROR: AutoSnapshot failed: unable to create database backup - Evolution CMS {$evolutionVersion}", $debugMode);
}

autoBackupLog("--- END AUTOSNAPSHOT 1.4.x ---", $debugMode);