import 'dart:io';
import 'dart:async';
import 'dart:convert';

/// System Command Executor with verbose output
class SysCom {
  /// Runs a system command and returns detailed output as a Map
  Future<Map<String, dynamic>> runCommand(
    String command, {
    List<String>? arguments,
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeStderr = true,
    Duration? timeout,
  }) async {
    final startTime = DateTime.now();
    final stopwatch = Stopwatch()..start();
    
    try {
      // Parse the command string into command and args
      final parsed = _parseCommand(command, arguments);
      final cmd = parsed['command'] as String;
      final args = parsed['args'] as List<String>;
      
      // Log the command being executed
      _logCommand(cmd, args);
      
      // Execute the command with optional timeout
      final result = timeout != null
          ? await _executeWithTimeout(cmd, args, timeout, workingDirectory, environment)
          : await _executeCommand(cmd, args, workingDirectory, environment);
      
      // Calculate execution time
      stopwatch.stop();
      final executionTime = stopwatch.elapsed;
      
      // Build the response map
      return {
        'success': result.exitCode == 0,
        'exit_code': result.exitCode,
        'response': result.stdout.toString(),
        'error': includeStderr ? result.stderr.toString() : '',
        'command': command,
        'full_command': '$cmd ${args.join(' ')}'.trim(),
        'working_directory': workingDirectory ?? Directory.current.path,
        'timestamp': startTime.toIso8601String(),
        'execution_time_ms': executionTime.inMilliseconds,
        'execution_time_formatted': _formatDuration(executionTime),
        'pid': result.pid,
      };
      
    } catch (e, stackTrace) {
      stopwatch.stop();
      final executionTime = stopwatch.elapsed;
      
      return {
        'success': false,
        'exit_code': -1,
        'response': '',
        'error': e.toString(),
        'command': command,
        'full_command': command,
        'working_directory': workingDirectory ?? Directory.current.path,
        'timestamp': startTime.toIso8601String(),
        'execution_time_ms': executionTime.inMilliseconds,
        'execution_time_formatted': _formatDuration(executionTime),
        'pid': null,
        'exception': e.toString(),
        'stack_trace': stackTrace.toString(),
      };
    }
  }
  
  /// Runs a system command in the background (non-blocking) and returns the PID.
  /// This is used for services like the Python HTTP server.
  Future<Map<String, dynamic>> runBackgroundCommand(
    String command, {
    List<String>? arguments,
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final startTime = DateTime.now();
    final stopwatch = Stopwatch()..start();

    try {
      final parsed = _parseCommand(command, arguments);
      final cmd = parsed['command'] as String;
      final args = parsed['args'] as List<String>;

      _logCommand(cmd, args, type: 'BACKGROUND');
      
      // Use Process.start to launch the process
      final process = await Process.start(
        cmd,
        args,
        workingDirectory: workingDirectory,
        environment: environment,
        // Using runInShell: false is generally safer, but might require explicit path setup
        runInShell: true, 
      );
      
      // The process is running. We return the PID immediately.
      stopwatch.stop();
      final executionTime = stopwatch.elapsed;
      
      // Optionally listen to stdout/stderr in the background to prevent buffer overflow,
      // but we don't block on the streams.
      process.stdout.listen((_) {}).onDone(() => print('[SysCom:PID ${process.pid}] Background process stdout done.'));
      process.stderr.listen((_) {}).onDone(() => print('[SysCom:PID ${process.pid}] Background process stderr done.'));
      
      // Process.run never returns a null PID, so we can cast safely.
      final pid = process.pid;

      return {
        'success': true,
        'exit_code': null, // No exit code yet, running in background
        'response': 'Process started in background.',
        'error': '',
        'command': command,
        'full_command': '$cmd ${args.join(' ')}'.trim(),
        'working_directory': workingDirectory ?? Directory.current.path,
        'timestamp': startTime.toIso8601String(),
        'execution_time_ms': executionTime.inMilliseconds,
        'execution_time_formatted': _formatDuration(executionTime),
        'pid': pid,
      };

    } catch (e, stackTrace) {
      stopwatch.stop();
      final executionTime = stopwatch.elapsed;
      
      return {
        'success': false,
        'exit_code': -1,
        'response': '',
        'error': e.toString(),
        'command': command,
        'full_command': command,
        'working_directory': workingDirectory ?? Directory.current.path,
        'timestamp': startTime.toIso8601String(),
        'execution_time_ms': executionTime.inMilliseconds,
        'execution_time_formatted': _formatDuration(executionTime),
        'pid': null,
        'exception': e.toString(),
        'stack_trace': stackTrace.toString(),
      };
    }
  }


  /// Parse command string and return properly typed Map
  Map<String, dynamic> _parseCommand(String command, List<String>? arguments) {
    // If arguments are provided, use them directly
    if (arguments != null) {
      return {
        'command': command,
        'args': arguments,
      };
    }
    
    // Parse command string into command and args
    final parts = command.split(' ');
    
    // Handle quoted arguments properly
    final parsedParts = <String>[];
    String currentPart = '';
    bool inQuotes = false;
    String quoteChar = '';
    
    for (int i = 0; i < parts.length; i++) {
      final part = parts[i];
      
      if (part.isEmpty) continue;
      
      // Check if we're starting a quoted section
      if (!inQuotes && (part.startsWith('"') || part.startsWith("'"))) {
        inQuotes = true;
        quoteChar = part[0];
        currentPart = part.substring(1);
        
        // Check if the quote ends in the same part
        if (part.endsWith(quoteChar) && part.length > 1) {
          inQuotes = false;
          parsedParts.add(currentPart.substring(0, currentPart.length - 1));
          currentPart = '';
        }
      } 
      // Check if we're ending a quoted section
      else if (inQuotes && part.endsWith(quoteChar)) {
        inQuotes = false;
        currentPart += ' ' + part.substring(0, part.length - 1);
        parsedParts.add(currentPart);
        currentPart = '';
      } 
      // We're inside a quoted section
      else if (inQuotes) {
        currentPart += ' ' + part;
      } 
      // Normal unquoted part
      else {
        parsedParts.add(part);
      }
    }
    
    // Handle case where we ended with an unclosed quote
    if (inQuotes) {
      parsedParts.add(currentPart);
    }
    
    // Extract command and args
    final cmd = parsedParts.isNotEmpty ? parsedParts.first : command;
    final args = parsedParts.length > 1 ? parsedParts.sublist(1) : <String>[];
    
    return {
      'command': cmd,
      'args': args,
    };
  }
  
  /// Execute command normally
  Future<ProcessResult> _executeCommand(
    String command,
    List<String> args,
    String? workingDirectory,
    Map<String, String>? environment,
  ) async {
    // For Windows, we need to handle shell commands differently
    if (Platform.isWindows) {
      // Check if this is a built-in shell command
      final shellCommands = {'dir', 'copy', 'del', 'move', 'mkdir', 'rd', 'cls', 'type'};
      
      if (shellCommands.contains(command.toLowerCase())) {
        // Use cmd.exe for shell commands
        final shellArgs = ['/c', command, ...args];
        return await Process.run('cmd', shellArgs,
          workingDirectory: workingDirectory,
          environment: environment,
          runInShell: false,
        );
      }
    }
    
    // For regular commands
    return await Process.run(command, args,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
    );
  }
  
  /// Execute command with timeout
  Future<ProcessResult> _executeWithTimeout(
    String command,
    List<String> args,
    Duration timeout,
    String? workingDirectory,
    Map<String, String>? environment,
  ) async {
    // For Windows shell commands
    if (Platform.isWindows) {
      final shellCommands = {'dir', 'copy', 'del', 'move', 'mkdir', 'rd', 'cls', 'type'};
      
      if (shellCommands.contains(command.toLowerCase())) {
        return await _executeWithTimeout(
          'cmd',
          ['/c', command, ...args],
          timeout,
          workingDirectory,
          environment,
        );
      }
    }
    
    final process = await Process.start(
      command,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    
    // Collect output
    process.stdout.transform(utf8.decoder).listen(stdoutBuffer.write);
    process.stderr.transform(utf8.decoder).listen(stderrBuffer.write);
    
    // Wait for process with timeout
    final exitFuture = process.exitCode;
    final timeoutFuture = Future.delayed(timeout, () => -1);
    
    final exitCode = await Future.any([exitFuture, timeoutFuture]);
    
    if (exitCode == -1) {
      // Timeout occurred
      try {
        process.kill();
      } catch (e) {
        // Ignore kill errors
      }
      throw TimeoutException('Command timed out after $timeout', timeout);
    }
    
    return ProcessResult(
      process.pid,
      exitCode,
      stdoutBuffer.toString(),
      stderrBuffer.toString(),
    );
  }
  
  /// Format duration for readability
  String _formatDuration(Duration duration) {
    if (duration.inSeconds < 1) {
      return '${duration.inMilliseconds}ms';
    } else if (duration.inMinutes < 1) {
      return '${duration.inSeconds}s ${duration.inMilliseconds % 1000}ms';
    } else {
      return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
    }
  }
  
  /// Log command execution (optional)
  void _logCommand(String command, List<String> args, {String type = 'NORMAL'}) {
    print('[SysCom:$type] Executing: $command ${args.join(' ')}');
  }
  
  // --- Additional convenience methods ---
  
  /// Run command and just return the output string (simplified)
  Future<String> run(String command, {List<String>? args}) async {
    final result = await runCommand(command, arguments: args);
    if (result['success'] == true) {
      return result['response'].toString();
    } else {
      throw Exception('Command failed: ${result['error']}');
    }
  }
  
  /// Check if a command exists
  Future<bool> commandExists(String command) async {
    try {
      if (Platform.isWindows) {
        final result = await runCommand('where $command');
        return result['success'] && result['response'].toString().isNotEmpty;
      } else {
        final result = await runCommand('which $command');
        return result['success'] && result['response'].toString().isNotEmpty;
      }
    } catch (e) {
      return false;
    }
  }
  
  /// Get current directory listing
  Future<List<String>> listDirectory({String? path}) async {
    final dir = path ?? Directory.current.path;
    // Using a simpler command than in the original SysCom to avoid complex parsing
    final result = await runCommand('dir /B "$dir"'); 
    
    if (result['success']) {
      final lines = result['response'].toString().split('\n');
      return lines.map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
    }
    
    return [];
  }
}

/// Simplified version for quick usage
class SimpleSysCom {
  /// Run a command and get the output as a string
  static Future<String> execute(String command, {List<String>? args}) async {
    final sysCom = SysCom();
    final result = await sysCom.runCommand(command, arguments: args);
    
    if (result['success'] == true) {
      return result['response'].toString();
    } else {
      throw Exception('Command failed: ${result['error']}');
    }
  }
  
  /// Run a command and get full details
  static Future<Map<String, dynamic>> executeDetailed(
    String command, {
    List<String>? args,
    String? workingDirectory,
  }) async {
    final sysCom = SysCom();
    return await sysCom.runCommand(
      command,
      arguments: args,
      workingDirectory: workingDirectory,
    );
  }
}
