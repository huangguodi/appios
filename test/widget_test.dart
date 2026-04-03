// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/views/dialogs/redeem_key_dialog.dart';
import 'package:app/views/dialogs/ticket_dialog.dart';

void main() {
  testWidgets('RedeemKeyDialog renders redeem form', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => RedeemKeyDialog.show(context),
                  child: const Text('open'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('立即兑换'), findsOneWidget);
  });

  testWidgets('TicketDialog renders service chat page', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => TicketDialog.show(context),
                  child: const Text('support'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('support'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('人工客服'), findsWidgets);
    expect(find.text('发送'), findsOneWidget);
  });
}
