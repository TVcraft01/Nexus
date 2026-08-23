import 'package:flutter/material.dart';

import '../mesh/mesh_service.dart';
import 'assistant_view.dart';
import 'devices_view.dart';
import 'settings_view.dart';

class HomeShell extends StatefulWidget {
  final MeshService mesh;
  const HomeShell({super.key, required this.mesh});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  ClipEntry? _lastShown;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.mesh,
      builder: (context, _) {
        // Show a friendly banner the moment a clip arrives from another device.
        final incoming = widget.mesh.lastIncomingClip;
        if (incoming != null && incoming != _lastShown) {
          _lastShown = incoming;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Copied on ${incoming.fromName ?? 'another device'}: '
                  '“${incoming.text.length > 60 ? '${incoming.text.substring(0, 60)}…' : incoming.text}”'),
              action: SnackBarAction(
                label: 'Copy here',
                textColor: Theme.of(context).colorScheme.primary,
                onPressed: () => widget.mesh.clipboard.writeText(incoming.text),
              ),
            ));
          });
        }

        final views = [
          DevicesView(mesh: widget.mesh),
          const AssistantView(),
          SettingsView(mesh: widget.mesh),
        ];

        return Scaffold(
          body: IndexedStack(index: _index, children: views),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.devices_rounded), label: 'Devices'),
              NavigationDestination(icon: Icon(Icons.mic_none_rounded), label: 'Assistant'),
              NavigationDestination(icon: Icon(Icons.tune_rounded), label: 'Settings'),
            ],
          ),
        );
      },
    );
  }
}
