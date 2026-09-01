enum UserRole { customer, driver, admin }

enum DriverApproval { draft, pending, approved, rejected, suspended }

enum RideStatus {
  searching,
  accepted,
  driverArriving,
  driverArrived,
  inProgress,
  completed,
  cancelled,
}

class Profile {
  const Profile({required this.id, required this.fullName, required this.role});
  final String id;
  final String fullName;
  final UserRole role;

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        id: json['id'] as String,
        fullName: json['full_name'] as String,
        role: UserRole.values.byName(json['role'] as String),
      );
}

class GeoPoint {
  const GeoPoint(this.latitude, this.longitude, {this.label});
  final double latitude;
  final double longitude;
  final String? label;
}

class FareEstimate {
  const FareEstimate({required this.amount, required this.currency});
  final double amount;
  final String currency;
}

class Ride {
  const Ride({
    required this.id,
    required this.status,
    required this.pickup,
    required this.destination,
    this.driverId,
    this.estimatedFare,
    this.distanceKm,
    this.durationMinutes,
    this.finalFare,
    this.requestedAt,
    this.completedAt,
    this.cancelledAt,
    this.cancellationReason,
    this.actualDistanceKm,
    this.actualDurationMinutes,
    this.paymentMethod = 'cash',
    this.paymentStatus = 'unpaid',
  });
  final String id;
  final RideStatus status;
  final GeoPoint pickup;
  final GeoPoint destination;
  final String? driverId;
  final double? estimatedFare;
  final double? distanceKm;
  final int? durationMinutes;
  final double? finalFare;
  final DateTime? requestedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final String? cancellationReason;
  final double? actualDistanceKm;
  final int? actualDurationMinutes;
  final String paymentMethod;
  final String paymentStatus;

  factory Ride.fromJson(Map<String, dynamic> json) => Ride(
        id: json['id'] as String,
        status: RideStatus.values.byName(
          (json['status'] as String).replaceAllMapped(
            RegExp(r'_([a-z])'),
            (match) => match.group(1)!.toUpperCase(),
          ),
        ),
        pickup: GeoPoint(
          (json['pickup_lat'] as num).toDouble(),
          (json['pickup_lng'] as num).toDouble(),
          label: json['pickup_address'] as String?,
        ),
        destination: GeoPoint(
          (json['destination_lat'] as num).toDouble(),
          (json['destination_lng'] as num).toDouble(),
          label: json['destination_address'] as String?,
        ),
        driverId: json['driver_id'] as String?,
        estimatedFare: (json['estimated_fare'] as num?)?.toDouble(),
        distanceKm: (json['estimated_distance_km'] as num?)?.toDouble(),
        durationMinutes: json['estimated_duration_minutes'] as int?,
        finalFare: (json['final_fare'] as num?)?.toDouble(),
        requestedAt: DateTime.tryParse('${json['requested_at'] ?? ''}'),
        completedAt: DateTime.tryParse('${json['completed_at'] ?? ''}'),
        cancelledAt: DateTime.tryParse('${json['cancelled_at'] ?? ''}'),
        cancellationReason: json['cancellation_reason'] as String?,
        actualDistanceKm: (json['actual_distance_km'] as num?)?.toDouble(),
        actualDurationMinutes: json['actual_duration_minutes'] as int?,
        paymentMethod: json['payment_method'] as String? ?? 'cash',
        paymentStatus: json['payment_status'] as String? ?? 'unpaid',
      );
}
