// Browsing another device's disk, as a page of its own.
//
// [FilesView] is written as a tab body: it draws its own "Files" header and a
// chip per paired device, because on the phone it *is* the Files screen. The
// shell is a different shape — its Files tab lists this device, and another
// device's folder is something you ask for from that device's row. So the view
// is mounted here, under a page bar, with its own header turned off: one title
// over one listing, and a back button where the tab bar was.
import 'package:flutter/material.dart';

import '../mesh/mesh_service.dart' show MeshService;
import 'files_view.dart';

class RemoteFilesPage extends StatelessWidget {
  const RemoteFilesPage({super.key, required this.mesh, this.deviceId});

  /// The running mesh. Everything on this page — the listing, the download, the
  /// rename and the delete — is that one object's API.
  final MeshService mesh;

  /// The peer to open on: the row the user tapped. Null opens on the first
  /// device the mesh knows, which is what the back-facing case wants (a page
  /// opened without a device in mind).
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    // No colours of its own: the app theme's scaffold background is the page's
    // background, and the bar inherits the same theme the tab it was opened
    // from is drawn on.
    return Scaffold(
      appBar: AppBar(title: const Text('Browse devices')),
      body: SafeArea(
        child: FilesView(
          mesh: mesh,
          initialDeviceId: deviceId,
          showHeader: false,
        ),
      ),
    );
  }
}
