import 'package:flutter_test/flutter_test.dart';
import 'package:request_ride/src/domain/models.dart';

void main() {
  test('ride parses snake-case status', () {
    final ride = Ride.fromJson({
      'id': 'ride-1',
      'status': 'driver_arriving',
      'pickup_lat': -26.2041,
      'pickup_lng': 28.0473,
      'destination_lat': -25.7479,
      'destination_lng': 28.2293,
      'estimated_fare': 150,
    });
    expect(ride.status, RideStatus.driverArriving);
    expect(ride.estimatedFare, 150);
  });
}
