import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'core/player_store.dart';
import 'core/update_client.dart';
import 'ui/player_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final support = await getApplicationSupportDirectory();
    final store = await PlayerStore.open(Directory('${support.path}/player'));
    UpdateClient? updates;
    try {
      final config = jsonDecode(
        await rootBundle.loadString('assets/config.json'),
      ) as Map<String, dynamic>;
      updates = UpdateClient(
        store,
        config['supabaseUrl'] as String,
        config['supabasePublishableKey'] as String,
      );
    } catch (_) {
      // A missing online configuration must never prevent offline play.
    }
    runApp(PlayerApp(store: store, updates: updates));
  } catch (_) {
    runApp(
      MaterialApp(
        theme: playerTheme,
        home: const Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Не удалось открыть хранилище. Освободите место на устройстве и перезапустите приложение.',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
