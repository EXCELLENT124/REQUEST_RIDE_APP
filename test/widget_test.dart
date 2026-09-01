// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:request_ride/src/app.dart';

void main() {
  testWidgets('shows setup guidance without runtime configuration',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: RequestRideApp(configured: false)),
    );
    expect(find.text('Request Ride'), findsOneWidget);
    expect(find.textContaining('SUPABASE_URL'), findsOneWidget);
  });
}
