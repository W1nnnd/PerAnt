// SPDX-License-Identifier: GPL-3.0-only
import 'workspace_state.dart';
import 'persistence_native.dart' as platform;

Future<WorkspacePersistence> openWorkspacePersistence() =>
    platform.openPersistence();
