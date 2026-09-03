import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/models.dart';

class Backend {
  Backend(this.client);
  final SupabaseClient client;

  User? get currentUser => client.auth.currentUser;

  Stream<AuthState> get authChanges => client.auth.onAuthStateChange;

  Future<void> signIn(String email, String password) =>
      client.auth.signInWithPassword(email: email, password: password);

  Future<bool> register({
    required String email,
    required String password,
    required String fullName,
    required UserRole role,
  }) async {
    final response = await client.auth.signUp(
      email: email,
      password: password,
      data: {'full_name': fullName, 'requested_role': role.name},
    );
    return response.session == null;
  }

  Future<void> signOut() => client.auth.signOut();

  Future<void> sendPasswordReset(String email) =>
      client.auth.resetPasswordForEmail(
        email,
        redirectTo: 'io.supabase.flutter://reset-callback/',
      );

  Future<void> updatePassword(String password) => client.auth.updateUser(
        UserAttributes(password: password),
      );

  Future<Profile?> getProfile() async {
    final user = currentUser;
    if (user == null) return null;
    final row =
        await client.from('profiles').select().eq('id', user.id).single();
    return Profile.fromJson(row);
  }

  Future<Map<String, dynamic>> getProfileDetails() async {
    final user = currentUser!;
    return Map<String, dynamic>.from(
      await client.from('profiles').select().eq('id', user.id).single(),
    );
  }

  Future<String?> getProfilePhotoUrl() async {
    final details = await getProfileDetails();
    final path = details['avatar_path'] as String?;
    if (path == null || path.isEmpty) return null;
    return client.storage
        .from('profile-photos')
        .createSignedUrl(path, 60 * 60);
  }

  Future<String> uploadProfilePhoto(Uint8List bytes, String fileName) async {
    final user = currentUser;
    if (user == null) throw StateError('You are not signed in.');
    if (bytes.length > 5 * 1024 * 1024) {
      throw ArgumentError('Profile photo must be 5 MB or smaller.');
    }
    final rawExtension = fileName.split('.').last.toLowerCase();
    final extension = switch (rawExtension) {
      'jpg' || 'jpeg' => 'jpg',
      'png' => 'png',
      'webp' => 'webp',
      _ => throw ArgumentError('Choose a JPG, PNG or WebP image.'),
    };
    final contentType = switch (extension) {
      'jpg' => 'image/jpeg',
      'png' => 'image/png',
      _ => 'image/webp',
    };
    final previous = await getProfileDetails();
    final previousPath = previous['avatar_path'] as String?;
    final path = '${user.id}/profile.$extension';
    await client.storage.from('profile-photos').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            upsert: true,
            contentType: contentType,
            cacheControl: '3600',
          ),
        );
    await client
        .from('profiles')
        .update({'avatar_path': path}).eq('id', user.id);
    if (previousPath != null && previousPath != path) {
      await client.storage.from('profile-photos').remove([previousPath]);
    }
    return client.storage
        .from('profile-photos')
        .createSignedUrl(path, 60 * 60);
  }

  Future<void> updateProfile({
    required String fullName,
    required String phone,
    required String emergencyName,
    required String emergencyPhone,
    required bool privacyConsent,
  }) =>
      client.rpc('update_my_profile', params: {
        'p_full_name': fullName,
        'p_phone': phone,
        'p_emergency_name': emergencyName,
        'p_emergency_phone': emergencyPhone,
        'p_consent': privacyConsent,
      });

  Future<void> requestAccountDeletion() =>
      client.rpc('request_account_deletion');

  Future<void> setDriverOnline(bool online, GeoPoint? point) async {
    await client.rpc(
      'set_driver_availability',
      params: {
        'p_online': online,
        'p_lat': point?.latitude,
        'p_lng': point?.longitude,
      },
    );
  }

  Future<List<Map<String, dynamic>>> nearbyOnlineDrivers(
    GeoPoint customerLocation,
  ) async =>
      List<Map<String, dynamic>>.from(
        await client.rpc(
          'nearby_online_drivers',
          params: {
            'p_lat': customerLocation.latitude,
            'p_lng': customerLocation.longitude,
          },
        ),
      );

  Future<FareEstimate> estimateFare({
    required double distanceKm,
    required int durationMinutes,
  }) async {
    final value = await client.rpc(
      'estimate_fare',
      params: {
        'p_distance_km': distanceKm,
        'p_duration_minutes': durationMinutes,
      },
    );
    return FareEstimate(amount: (value as num).toDouble(), currency: 'ZAR');
  }

  Future<String> requestRide({
    required GeoPoint pickup,
    required GeoPoint destination,
    required double distanceKm,
    required int durationMinutes,
    required String driverId,
    String paymentMethod = 'cash',
  }) async {
    final id = await client.rpc(
      'request_ride_for_driver',
      params: {
        'p_pickup_lat': pickup.latitude,
        'p_pickup_lng': pickup.longitude,
        'p_pickup_address': pickup.label,
        'p_destination_lat': destination.latitude,
        'p_destination_lng': destination.longitude,
        'p_destination_address': destination.label,
        'p_distance_km': distanceKm,
        'p_duration_minutes': durationMinutes,
        'p_driver_id': driverId,
      },
    );
    await client.rpc('set_ride_payment_method', params: {
      'p_ride_id': id,
      'p_method': paymentMethod,
    });
    return id as String;
  }

  Future<String> reportSafetyIncident({
    String? rideId,
    required String type,
    required String details,
    GeoPoint? location,
  }) async =>
      await client.rpc('report_safety_incident', params: {
        'p_ride_id': rideId,
        'p_type': type,
        'p_details': details,
        'p_lat': location?.latitude,
        'p_lng': location?.longitude,
      }) as String;

  Future<List<Map<String, dynamic>>> safetyIncidents() async =>
      List<Map<String, dynamic>>.from(
        await client
            .from('safety_incidents')
            .select('*, profiles!safety_incidents_reported_by_fkey(full_name)')
            .order('created_at', ascending: false),
      );

  Future<void> acceptRide(String rideId) =>
      client.rpc('accept_ride', params: {'p_ride_id': rideId});

  Future<void> declineRide(String rideId, String reason) => client.rpc(
        'decline_ride_offer',
        params: {'p_ride_id': rideId, 'p_reason': reason},
      );

  Future<List<Ride>> availableRideRequests() async =>
      List<Map<String, dynamic>>.from(
        await client.rpc('available_ride_requests'),
      ).map(Ride.fromJson).toList();

  Stream<List<Ride>> availableRideRequestsStream() async* {
    while (true) {
      yield await availableRideRequests();
      await Future<void>.delayed(const Duration(seconds: 8));
    }
  }

  Future<void> transitionRide(String rideId, RideStatus status) => client.rpc(
        'transition_ride',
        params: {'p_ride_id': rideId, 'p_next_status': _status(status)},
      );

  Future<void> cancelRide(String rideId, String reason) => client.rpc(
        'cancel_ride',
        params: {'p_ride_id': rideId, 'p_reason': reason},
      );

  Future<void> rateRide(String rideId, int score, String comment) => client.rpc(
        'rate_ride',
        params: {'p_ride_id': rideId, 'p_score': score, 'p_comment': comment},
      );

  Future<Map<String, dynamic>?> myRating(String rideId) async {
    final user = currentUser;
    if (user == null) return null;
    return client
        .from('ratings')
        .select()
        .eq('ride_id', rideId)
        .eq('author_id', user.id)
        .maybeSingle();
  }

  Future<void> updateDriverLocation(GeoPoint point, {String? rideId}) =>
      client.rpc(
        'update_driver_location',
        params: {
          'p_lat': point.latitude,
          'p_lng': point.longitude,
          'p_ride_id': rideId,
        },
      );

  Future<Map<String, dynamic>?> driverApplication() async {
    final user = currentUser;
    if (user == null) return null;
    return client
        .from('driver_applications')
        .select()
        .eq('driver_id', user.id)
        .maybeSingle();
  }

  Future<void> saveVehicle({
    required String make,
    required String model,
    required int year,
    required String colour,
    required String numberPlate,
    required String bodyType,
  }) async {
    final user = currentUser!;
    await client.from('vehicles').upsert({
      'driver_id': user.id,
      'make': make,
      'model': model,
      'year': year,
      'colour': colour,
      'number_plate': numberPlate.toUpperCase(),
      'vehicle_type': 'car',
      'body_type': bodyType,
    }, onConflict: 'driver_id');
  }

  Future<void> uploadDriverDocument({
    required String type,
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    DateTime? expiresAt,
  }) async {
    final user = currentUser!;
    final safeName = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '${user.id}/$type-$safeName';
    await client.storage.from('driver-documents').uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(upsert: true),
        );
    await client.from('driver_documents').upsert({
      'driver_id': user.id,
      'type': type,
      'storage_path': path,
      'verified': false,
      'file_name': safeName,
      'mime_type': mimeType,
      'file_size_bytes': bytes.length,
      'expires_at': expiresAt?.toIso8601String().split('T').first,
    }, onConflict: 'driver_id,type');
  }

  Future<void> submitDriverApplication(String proofOfAddress) async {
    await client.rpc('submit_driver_application', params: {
      'p_proof_of_address': proofOfAddress,
    });
  }

  Future<List<Map<String, dynamic>>> driverApplications() async {
    final applications = List<Map<String, dynamic>>.from(
      await client
          .from('driver_applications')
          .select(
            '*, profiles!driver_applications_driver_id_fkey(full_name,phone)',
          )
          .order('submitted_at', ascending: false),
    );
    if (applications.isEmpty) return applications;
    final ids = applications.map((row) => row['driver_id'] as String).toList();
    final vehicles = List<Map<String, dynamic>>.from(
      await client.from('vehicles').select().inFilter('driver_id', ids),
    );
    final byDriver = {
      for (final vehicle in vehicles) vehicle['driver_id'] as String: vehicle,
    };
    return applications
        .map((row) => <String, dynamic>{
              ...row,
              'vehicles': byDriver[row['driver_id']],
            })
        .toList();
  }

  Future<void> setDriverStatus(String driverId, String status, String reason) =>
      client.rpc('admin_set_driver_status', params: {
        'p_driver_id': driverId,
        'p_status': status,
        'p_reason': reason,
      });

  Future<void> setFareRule({
    required String name,
    required double base,
    required double perKm,
    required double perMinute,
    required double minimum,
    required double booking,
  }) =>
      client.rpc('admin_set_fare', params: {
        'p_name': name,
        'p_base': base,
        'p_per_km': perKm,
        'p_per_minute': perMinute,
        'p_minimum': minimum,
        'p_booking': booking,
      });

  Future<Map<String, dynamic>> tripDetails(String rideId) async =>
      Map<String, dynamic>.from(await client
          .from('rides')
          .select(
              '*, fare_rules(*), vehicles(*), profiles!rides_driver_id_fkey(full_name,phone)')
          .eq('id', rideId)
          .single());

  Future<List<Map<String, dynamic>>> pendingDrivers() async {
    final applications = List<Map<String, dynamic>>.from(
      await client
          .from('driver_applications')
          .select(
            '*, profiles!driver_applications_driver_id_fkey(full_name,phone)',
          )
          .eq('status', 'pending')
          .order('submitted_at'),
    );
    if (applications.isEmpty) return applications;

    // Vehicles and applications both reference profiles, but they do not have
    // a direct foreign key between them. Fetch vehicles separately so
    // PostgREST does not attempt an invalid embedded relationship.
    final driverIds = applications
        .map((application) => application['driver_id'] as String)
        .toList();
    final vehicles = List<Map<String, dynamic>>.from(
      await client.from('vehicles').select().inFilter('driver_id', driverIds),
    );
    final vehicleByDriver = {
      for (final vehicle in vehicles) vehicle['driver_id'] as String: vehicle,
    };

    return applications
        .map(
          (application) => <String, dynamic>{
            ...application,
            'vehicles': vehicleByDriver[application['driver_id']],
          },
        )
        .toList();
  }

  Future<void> reviewDriver(
    String driverId,
    bool approve, {
    String? reason,
  }) =>
      client.rpc(
        'review_driver',
        params: {
          'p_driver_id': driverId,
          'p_approve': approve,
          'p_reason': reason,
        },
      );

  Future<List<Map<String, dynamic>>> driverDocuments(String driverId) async =>
      List<Map<String, dynamic>>.from(
        await client
            .from('driver_documents')
            .select()
            .eq('driver_id', driverId)
            .order('type'),
      );

  Future<String> driverDocumentUrl(String storagePath) =>
      client.storage.from('driver-documents').createSignedUrl(storagePath, 300);

  Future<List<Map<String, dynamic>>> activeFareRules() async =>
      List<Map<String, dynamic>>.from(
        await client.from('fare_rules').select().eq('active', true),
      );

  Stream<List<Ride>> rides({String? status}) {
    final base = client.from('rides').stream(primaryKey: ['id']);
    if (status != null) {
      return base
          .eq('status', status)
          .map((rows) => rows.map(Ride.fromJson).toList());
    }
    return base.map((rows) => rows.map(Ride.fromJson).toList());
  }

  Stream<Map<String, dynamic>?> trackRide(String rideId) => client
      .from('ride_tracking')
      .stream(primaryKey: ['ride_id'])
      .eq('ride_id', rideId)
      .map((rows) => rows.isEmpty ? null : rows.first);

  Stream<List<Map<String, dynamic>>> notifications() => client
      .from('notifications')
      .stream(primaryKey: ['id'])
      .order('created_at', ascending: false)
      .map((rows) => List<Map<String, dynamic>>.from(rows));

  Future<void> markNotificationRead(String id) => client
      .from('notifications')
      .update({'read_at': DateTime.now().toIso8601String()}).eq('id', id);

  Future<void> deleteNotification(String id) =>
      client.from('notifications').delete().eq('id', id);

  Future<void> clearNotifications() async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) throw StateError('You are not signed in.');
    await client.from('notifications').delete().eq('user_id', userId);
  }

  static String _status(RideStatus status) => status.name.replaceAllMapped(
        RegExp(r'[A-Z]'),
        (match) => '_${match.group(0)!.toLowerCase()}',
      );
}
