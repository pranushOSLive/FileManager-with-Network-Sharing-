import 'package:flutter/material.dart';
import 'package:network_share/sysCommands.dart'; 
import 'dart:io' show Platform; // Import Platform for OS check

class FileSys extends StatefulWidget {
  const FileSys({super.key});

  @override
  State<FileSys> createState() => _FileSysState();
}

// Add TickerProviderStateMixin for the blinking animation
class _FileSysState extends State<FileSys> with TickerProviderStateMixin {
  // --- Server State Management ---
  String _currentPath = "C:\\";
  late Future<List<String>> commandOutput;
  
  // State for the server
  String? _sharedPath; // Full path of the file/folder being shared
  String _serverStatus = 'idle'; // 'idle', 'active', 'stopping'
  final int _serverPort = 8585;
  String? _serverProcessId; // Actual Process ID returned by SysCom
  
  final SysCom _sysCom = SysCom(); // Instance of SysCom

  // Animation for the blinking status dot
  late AnimationController _animationController;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    commandOutput = _fetchDirectoryContents(_currentPath);
    
    // Setup for blinking animation
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _animation = Tween(begin: 0.2, end: 1.0).animate(_animationController);
  }

  @override
  void dispose() {
    // Attempt to stop the server on app dispose to clean up resources
    if (_serverStatus == 'active') {
      _stopSharing(); 
    }
    _animationController.dispose();
    super.dispose();
  }

  // Helper: Simple heuristic to guess if an item is a file (has extension)
  bool _isFile(String name) {
    // Note: This is a heuristic. A file is assumed if it has an extension (a dot not at the start or end).
    final lastDotIndex = name.lastIndexOf('.');
    return lastDotIndex > 0 && lastDotIndex < name.length - 1;
  }

  // Helper: Shows a custom dialog message (replaces alert())
  void _showMessageDialog(String title, String content, {List<Widget>? actions}) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(title),
          // Use SelectableText here so the user can copy the URL and messages
          content: SelectableText(content), 
          actions: actions ?? [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }
  
  // HELPER: Splits the full path into the item name and its parent directory
  Map<String, String> _splitPath(String fullPath) {
    // Normalize separator
    final normalizedPath = fullPath.replaceAll('/', '\\');
    
    // Find the last separator to split the name and parent
    int lastSeparatorIndex = normalizedPath.lastIndexOf('\\');
    if (lastSeparatorIndex == -1) {
        // Should not happen for a full path, but handle it
        return {'parent': '', 'name': normalizedPath};
    }
    
    String name = normalizedPath.substring(lastSeparatorIndex + 1);
    String parent = normalizedPath.substring(0, lastSeparatorIndex + 1);

    // If the path is just a drive root (e.g., "C:\"), the name is empty, parent is "C:\"
    if (name.isEmpty && parent.endsWith('\\')) {
        name = parent.substring(0, parent.length - 1);
        parent = '';
    }
    
    // Ensure parent is not empty if it's a drive root (e.g. C:\)
    if (parent.isEmpty && normalizedPath.contains(':')) {
        parent = normalizedPath.substring(0, 3); // e.g. C:\
        name = normalizedPath.substring(3);
        if (name.isEmpty) {
            name = parent.substring(0, 2);
            parent = '';
        }
    }
    
    // Handle case like C:\Windows
    if (name.isEmpty) {
        // Re-calculate for folders that already have a trailing slash (like how _changeDirectory works)
        lastSeparatorIndex = normalizedPath.substring(0, normalizedPath.length - 1).lastIndexOf('\\');
        name = normalizedPath.substring(lastSeparatorIndex + 1, normalizedPath.length - 1);
        parent = normalizedPath.substring(0, lastSeparatorIndex + 1);
    }


    return {'parent': parent, 'name': name};
  }


  // --- Server Control Logic (Updated to use SysCom) ---

  Future<void> _startSharing(String path) async {
    setState(() {
      _serverStatus = 'starting';
    });

    final pathInfo = _splitPath(path);
    final String itemName = pathInfo['name']!;   
    final bool isFile = _isFile(itemName);

    String serverRoot; 
    String urlSuffix;
    String statusMessage;
    
    if (isFile) {
        // --- SCENARIO: Sharing a File ---
        // Python's http.server can only serve directories. To serve a file, we must serve its parent.
        serverRoot = pathInfo['parent']!; 
        urlSuffix = itemName; // Link directly to the file
        statusMessage = 'Note: The server is serving the entire parent directory ("${serverRoot}") to make "${itemName}" accessible.';
        
        // Handle drive root case
        if (serverRoot.isEmpty) {
            serverRoot = path.substring(0, path.length - itemName.length);
        }
    } else {
        // --- SCENARIO: Sharing a Folder/Directory ---
        // Run server in the selected directory to limit scope to its contents.
        // We use the full path of the item as the working directory.
        serverRoot = path.endsWith('\\') ? path : '$path\\'; 
        urlSuffix = ''; // Root of the server is now the shared folder
        statusMessage = 'Server is running directly inside the selected folder: "${serverRoot}". Only its contents are exposed.';
        
        // Handle drive root case
        if (path.length <= 3 && path.contains(':')) {
            serverRoot = path;
            urlSuffix = '';
        }
    }
    
    // Construct the system command to start the Python server
    final command = 'python';
    final arguments = ['-m', 'http.server', '$_serverPort'];

    try {
      var result = await _sysCom.runBackgroundCommand(
        command, 
        arguments: arguments,
        workingDirectory: serverRoot, // IMPORTANT: Run from the calculated root
      );

      if (result['success'] == true && result['pid'] != null) {
          String processId = result['pid'].toString();
          
          setState(() {
            _sharedPath = path;
            _serverStatus = 'active';
            _serverProcessId = processId;
          });
          
          final url = 'http://localhost:$_serverPort/$urlSuffix';
          _showMessageDialog(
            'Server Active: Sharing ${isFile ? 'File' : 'Folder'}', 
            '$statusMessage\n\nAccess it at: $url\n\n(Note: This requires Python installed on the system.)'
          );
      } else {
           throw Exception(result['error'] ?? 'Unknown error starting process.');
      }

    } catch (e) {
      setState(() {
        _serverStatus = 'idle';
        _sharedPath = null;
        _serverProcessId = null;
      });
      _showMessageDialog('Server Error', 'Failed to start Python server. Check if Python is installed or if port $_serverPort is available. Error: ${e.toString()}');
    }
  }

  Future<void> _stopSharing() async {
    if (_serverStatus != 'active' || _serverProcessId == null) return;

    setState(() {
      _serverStatus = 'stopping';
    });
    
    final pid = _serverProcessId!;
    
    // Determine the kill command based on the operating system
    final bool isWindows = Platform.isWindows;
    final String killCommand;
    final List<String> killArgs;
    
    if (isWindows) {
      // Windows: taskkill /F /PID [PID] /T (Forcefully terminate process by PID and its children)
      killCommand = 'taskkill';
      killArgs = ['/F', '/PID', pid, '/T']; // /T ensures the entire process tree is terminated
    } else {
      // Unix-like (Linux/macOS): kill -9 [PID] (Forcefully send signal 9)
      killCommand = 'kill';
      killArgs = ['-9', pid];
    }

    try {
      // Execute the command using separate command and arguments
      var result = await _sysCom.runCommand(
        killCommand, 
        arguments: killArgs,
      );
      
      // Log result for debugging purposes
      print('[StopSharing] Kill Command Result: $result');

      // Check for success (exit code 0 usually means success for both taskkill and kill)
      if (result['success'] == true) {
        setState(() {
          _serverStatus = 'idle';
          _sharedPath = null;
          _serverProcessId = null;
        });
        _showMessageDialog('Server Stopped', 'The network sharing server (PID: $pid) has been shut down.');
      } else {
        // Log the failure but reset state to avoid a zombie UI state
        final errorMsg = result['error'].toString().trim().replaceAll('\n', ' ');
        print('Warning: Kill command failed for PID $pid. Error: $errorMsg');

        setState(() {
            _serverStatus = 'idle';
            _sharedPath = null;
            _serverProcessId = null;
        });
        _showMessageDialog(
          'Server Stopped (Cleanup Warning)', 
          'The server state was reset, but the termination command failed (PID: $pid). Error details: $errorMsg'
        );
      }
      
    } catch (e) {
      setState(() {
        _serverStatus = 'active'; // Revert if stop fails catastrophically
      });
      _showMessageDialog('Stop Error', 'Failed to execute stop command for PID: $pid. Please kill the process manually. Error: ${e.toString()}');
    }
  }

  void _handleShareAttempt(String item) {
    final String fullPath = _currentPath.endsWith('\\') ? '$_currentPath$item' : '$_currentPath\\$item';

    if (_serverStatus == 'active' && _sharedPath != fullPath) {
      // Collision Prompt
      _showMessageDialog(
        'Server Busy',
        'Another item is already being shared: "$_sharedPath". Would you like to stop that sharing and start sharing "$fullPath"?',
        actions: <Widget>[
          TextButton(
            onPressed: () {
              Navigator.of(context).pop(); 
              _stopSharing().then((_) => _startSharing(fullPath));
            },
            child: const Text('Stop & Share This'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      );
    } else if (_serverStatus == 'active' && _sharedPath == fullPath) {
      // Tapped the same item (act as a stop button)
      _stopSharing();
    } else if (_serverStatus == 'idle') {
      // Server is idle, start sharing
      _startSharing(fullPath);
    }
  }
  
  void _handleWhiteCardDoubleTap(String item) {
    final String newItemPath = _currentPath.endsWith('\\') ? '$_currentPath$item' : '$_currentPath\\$item';
    
    if (_isFile(item)) {
      _showMessageDialog(
        'File Detected', 
        'This appears to be a file: "$item". No action will be taken.'
      );
    } else {
      _changeDirectory(newItemPath);
    }
  }

  // --- Utility Functions (Path Traversal, Dialog, Fetch Contents) ---

  List<String> _getAncestorPaths(String path) {
    if (path.isEmpty) return [];

    const String separator = '\\'; 
    
    final bool isRoot = path.length == 3 && path.endsWith(separator);
    final normalizedPath = (path.endsWith(separator) && !isRoot) 
                           ? path.substring(0, path.length - 1) 
                           : path;

    String driveRoot = (normalizedPath.length >= 2 && normalizedPath[1] == ':') 
                       ? normalizedPath.substring(0, 2) + separator 
                       : normalizedPath;

    List<String> ancestorPaths = [];
    String tempPath = normalizedPath;
    
    while (tempPath.length > driveRoot.length) {
        ancestorPaths.add(tempPath);
        
        int lastSeparatorIndex = tempPath.substring(0, tempPath.length - 1).lastIndexOf(separator);
        
        if (lastSeparatorIndex < 0) {
          break;
        }
        
        tempPath = tempPath.substring(0, lastSeparatorIndex + 1);
    }
    
    if (!ancestorPaths.contains(driveRoot)) {
        ancestorPaths.add(driveRoot);
    }

    return ancestorPaths;
  }

  void _showTraversalDialog() {
    final List<String> ancestors = _getAncestorPaths(_currentPath);
    
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Directory Traversal'),
          content: SizedBox(
            width: double.maxFinite, 
            height: 300, 
            child: ListView.builder(
              itemCount: ancestors.length,
              itemBuilder: (context, index) {
                final path = ancestors[index];
                return ListTile(
                  title: Text(path),
                  onTap: () {
                    Navigator.of(dialogContext).pop(); 
                    _changeDirectory(path); 
                  },
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  Future<List<String>> _fetchDirectoryContents(String path) async {
    String normalizedPath = path.endsWith('\\') ? path : '$path\\';

    final command = 'dir';
    final arguments = ['/B', normalizedPath];
    
    try {
      var output = await _sysCom.runCommand(command, arguments: arguments);
      
      if (output.containsKey("response") && output["response"] != null) {
        final responseString = output["response"] as String;
        
        final List<String> lines = responseString
            .split('\n')
            .where((line) => line.trim().isNotEmpty)
            .map((line) => line.trim())
            .toList();
        
        lines.insert(0, normalizedPath);
        return lines;
      }
      return [normalizedPath, "Command executed, but no valid content was found."];
    } catch (e) {
      return [path, "Error executing command: ${e.toString()}"];
    }
  }

  void _changeDirectory(String newPath) {
    final String normalizedPath = newPath.endsWith('\\') ? newPath : '$newPath\\';
    
    if (normalizedPath != _currentPath) {
      setState(() {
        _currentPath = normalizedPath;
        commandOutput = _fetchDirectoryContents(_currentPath); 
      });
    }
  }

  // --- Build Method ---

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: commandOutput,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting || _serverStatus == 'starting' || _serverStatus == 'stopping') {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(_serverStatus == 'starting' ? 'Starting Server...' : (_serverStatus == 'stopping' ? 'Stopping Server...' : 'Loading Directory...')),
              ],
            ),
          );
        } 
        
        if (snapshot.hasError) {
          return Center(child: Text('Fatal Error: ${snapshot.error}'));
        } 
        
        if (snapshot.hasData) {
          final List<String> lines = snapshot.data!;
          
          if (lines.isEmpty) {
            return const Center(child: Text("Directory is empty or command failed."));
          }

          final String currentDirectory = lines.first; 
          final List<String> contents = lines.sublist(1); 

          return Container(
            color: Colors.blueGrey.shade50, // Soft background color for the list area
            child: ListView.builder(
              itemCount: lines.length,
              itemBuilder: (context, index) {
                if (index == 0) {
                  // --- HEADER CARD: Status and Traversal ---
                  final bool isActive = _serverStatus == 'active';
                  
                  return InkWell(
                    onTap: _showTraversalDialog,
                    child: Card(
                      color: Colors.indigo.shade700, // Rich Blue Header
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      elevation: 8, // Higher elevation for depth
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15.0)), // More rounded corners
                      child: Padding(
                        padding: const EdgeInsets.all(20.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      // Server Status Text and Blinking Dot
                                      Row(
                                        children: [
                                          Text(
                                            isActive ? 'Server ACTIVE (Port $_serverPort)' : 'Server IDLE',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w800, 
                                              color: isActive ? Colors.lightGreenAccent : Colors.redAccent, // Vibrant status color
                                              fontSize: 14
                                            )
                                          ),
                                          const SizedBox(width: 8),
                                          // Blinking status dot
                                          FadeTransition(
                                            opacity: _animation,
                                            child: Container(
                                              width: 10,
                                              height: 10,
                                              decoration: BoxDecoration(
                                                color: isActive ? Colors.lightGreenAccent : Colors.redAccent,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      // Current Directory Path label
                                      Text(
                                        'Current Path:',
                                        style: TextStyle(color: Colors.indigo.shade300, fontSize: 12),
                                      ),
                                      // Current Directory Path value
                                      Text(
                                        currentDirectory,
                                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      const Text('Tap path to traverse directories', style: TextStyle(fontSize: 12, color: Colors.indigoAccent)),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 16),
                                
                                // Dedicated Stop Server Button (If active) or Traversal Icon (If idle)
                                if (isActive)
                                  ElevatedButton.icon(
                                    onPressed: _stopSharing,
                                    icon: const Icon(Icons.stop, size: 18),
                                    label: const Text('STOP', style: TextStyle(fontWeight: FontWeight.bold)),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red.shade400, // Brighter red
                                      foregroundColor: Colors.white,
                                      elevation: 4,
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  )
                                else
                                  // Visual indicator for traversal when idle
                                  Tooltip(
                                    message: 'Jump to Ancestor Directory',
                                    child: Icon(Icons.compare_arrows, color: Colors.indigoAccent.shade200, size: 30)
                                  ),
                              ],
                            ),
                            // Display shared path if active
                            if (isActive)
                              Padding(
                                padding: const EdgeInsets.only(top: 12.0),
                                child: SelectableText( // Make shared path text selectable too
                                  'Sharing: ${_sharedPath}',
                                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Colors.indigo.shade200),
                                ),
                              )
                          ],
                        ),
                      ),
                    ),
                  );
                } else {
                  // --- LIST ITEM CARD: File/Folder Listing ---
                  final String item = contents[index - 1];
                  final String itemFullPath = currentDirectory + item;
                  final bool isShared = _sharedPath == itemFullPath;
                  
                  return GestureDetector(
                    onDoubleTap: () => _handleWhiteCardDoubleTap(item),
                    child: Card(
                      color: Colors.white, 
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), 
                      elevation: isShared ? 6 : 2, // Higher elevation if shared
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10.0), 
                        side: isShared 
                              ? BorderSide(color: Colors.teal.shade400, width: 3) // Vibrant border for shared item
                              : BorderSide(color: Colors.grey.shade200, width: 1), // Subtle border when not shared
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Row(
                          children: [
                            // Icon
                            Icon(
                              _isFile(item) ? Icons.description_outlined : Icons.folder_open, 
                              color: _isFile(item) ? Colors.blueGrey : Colors.amber.shade700,
                              size: 24, 
                            ),
                            const SizedBox(width: 15),
                            // Text
                            Expanded(
                              child: Text(
                                item,
                                style: TextStyle(
                                  color: Colors.black87,
                                  fontSize: 15,
                                  fontWeight: isShared ? FontWeight.w600 : FontWeight.normal,
                                ),
                                overflow: TextOverflow.ellipsis, 
                              ),
                            ),
                            // Action Icons
                            // Share Icon
                            IconButton(
                              icon: Icon(
                                isShared ? Icons.stop_circle_outlined : Icons.share_rounded, 
                                color: isShared ? Colors.teal.shade500 : Colors.blue.shade600,
                                size: 26,
                              ),
                              tooltip: isShared ? 'Stop Sharing This' : 'Network Share',
                              onPressed: () => _handleShareAttempt(item),
                            ),
                            // Stop Server Icon (only visible if a DIFFERENT item is shared)
                            if (!isShared && _serverStatus == 'active')
                              IconButton(
                                icon: const Icon(Icons.stop_circle_outlined, color: Colors.redAccent, size: 26),
                                tooltip: 'Stop Active Server',
                                onPressed: _stopSharing,
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                }
              },
            ),
          );
        } 
        
        return const Center(child: Text("Unknown Error Occured!"));
      },
    );
  }
}
