import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as map;
import 'package:url_launcher/url_launcher.dart';

import '../data/backend.dart';
import '../data/mapping_service.dart';
import '../domain/models.dart';

Future<GeoPoint> _currentPoint() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw Exception('Turn on location services first.');
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    throw Exception('Location permission is required.');
  }
  final position = await Geolocator.getCurrentPosition();
  return GeoPoint(position.latitude, position.longitude);
}

double _distanceKm(GeoPoint a, GeoPoint b) {
  const radius = 6371.0;
  final lat = (b.latitude - a.latitude) * math.pi / 180;
  final lng = (b.longitude - a.longitude) * math.pi / 180;
  final value = math.sin(lat / 2) * math.sin(lat / 2) +
      math.cos(a.latitude * math.pi / 180) *
          math.cos(b.latitude * math.pi / 180) *
          math.sin(lng / 2) *
          math.sin(lng / 2);
  return radius * 2 * math.atan2(math.sqrt(value), math.sqrt(1 - value));
}

void _message(BuildContext context, Object value) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$value')));

Future<void> _cancelRideDialog(
  BuildContext context,
  Backend backend,
  Ride ride,
) async {
  final controller = TextEditingController();
  final reason = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Cancel ride'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 250,
        decoration: const InputDecoration(
          labelText: 'Reason for cancelling',
          hintText: 'For example: plans changed',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Keep ride'),
        ),
        FilledButton(
          onPressed: () {
            final value = controller.text.trim();
            if (value.length >= 3) Navigator.pop(context, value);
          },
          child: const Text('Cancel ride'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (reason == null || !context.mounted) return;
  try {
    await backend.cancelRide(ride.id, reason);
    if (context.mounted) _message(context, 'Ride cancelled');
  } catch (error) {
    if (context.mounted) _message(context, error);
  }
}

Future<void> _safetyDialog(
  BuildContext context,
  Backend backend,
  Ride ride,
) async {
  final action = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Trip safety'),
      content: const Text(
        'If anyone is in immediate danger, call emergency services. You can also report an SOS to the Request Ride administrator.',
      ),
      actions: [
        TextButton.icon(
          onPressed: () => Navigator.pop(context, 'share'),
          icon: const Icon(Icons.share),
          label: const Text('Copy trip details'),
        ),
        TextButton.icon(
          onPressed: () => Navigator.pop(context, 'call'),
          icon: const Icon(Icons.call),
          label: const Text('Call 112'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, 'sos'),
          icon: const Icon(Icons.sos),
          label: const Text('Send SOS'),
        ),
      ],
    ),
  );
  if (action == 'share') {
    await Clipboard.setData(ClipboardData(
      text:
          'Request Ride trip ${ride.id}\nPickup: ${ride.pickup.label ?? '${ride.pickup.latitude}, ${ride.pickup.longitude}'}\nDestination: ${ride.destination.label ?? '${ride.destination.latitude}, ${ride.destination.longitude}'}\nStatus: ${_rideStatusLabel(ride.status)}',
    ));
    if (context.mounted) _message(context, 'Trip details copied');
  } else if (action == 'call') {
    await launchUrl(Uri.parse('tel:112'));
  } else if (action == 'sos') {
    GeoPoint? location;
    try {
      location = await _currentPoint();
    } catch (_) {}
    await backend.reportSafetyIncident(
      rideId: ride.id,
      type: 'sos',
      details: 'SOS activated from the active-trip safety panel.',
      location: location,
    );
    if (context.mounted) {
      _message(context, 'SOS reported to Request Ride operations');
    }
  }
}

LocationSettings _driverLocationSettings() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 15,
      intervalDuration: const Duration(seconds: 10),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'Request Ride driver is online',
        notificationText: 'Sharing your location to receive and complete rides',
        enableWakeLock: true,
      ),
    );
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    return AppleSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 15,
      activityType: ActivityType.automotiveNavigation,
      pauseLocationUpdatesAutomatically: false,
      showBackgroundLocationIndicator: true,
      allowBackgroundLocationUpdates: true,
    );
  }
  return const LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 20,
  );
}

class CustomerWorkspace extends StatefulWidget {
  const CustomerWorkspace({required this.backend, super.key});
  final Backend backend;

  @override
  State<CustomerWorkspace> createState() => _CustomerWorkspaceState();
}

class _CustomerWorkspaceState extends State<CustomerWorkspace> {
  final mapping = MappingService();
  final destinationAddress = TextEditingController();
  final destinationLat = TextEditingController(text: '-26.1076');
  final destinationLng = TextEditingController(text: '28.0567');
  GeoPoint? pickup;
  FareEstimate? estimate;
  double? distance;
  int? duration;
  var busy = false;
  var loadingDrivers = false;
  List<Map<String, dynamic>> onlineDrivers = [];
  String? driverLoadError;
  Timer? driverRefresh;
  List<GeoPoint> routePoints = const [];
  List<GeoPoint> addressResults = const [];
  var searchingAddress = false;
  String paymentMethod = 'cash';

  @override
  void dispose() {
    driverRefresh?.cancel();
    destinationAddress.dispose();
    destinationLat.dispose();
    destinationLng.dispose();
    super.dispose();
  }

  void startDriverRefresh() {
    driverRefresh?.cancel();
    driverRefresh = Timer.periodic(
      const Duration(seconds: 10),
      (_) => loadOnlineDrivers(),
    );
  }

  Future<void> loadOnlineDrivers() async {
    final customerLocation = pickup;
    if (customerLocation == null || loadingDrivers) return;
    setState(() {
      loadingDrivers = true;
      driverLoadError = null;
    });
    try {
      final drivers = await widget.backend.nearbyOnlineDrivers(
        customerLocation,
      );
      if (mounted) setState(() => onlineDrivers = drivers);
    } catch (error) {
      if (mounted) setState(() => driverLoadError = '$error');
    } finally {
      if (mounted) setState(() => loadingDrivers = false);
    }
  }

  Future<void> locate() async {
    try {
      final point = await _currentPoint();
      setState(() => pickup = point);
      startDriverRefresh();
      await loadOnlineDrivers();
    } catch (error) {
      if (mounted) _message(context, error);
    }
  }

  void chooseDestination(map.LatLng point) {
    setState(() {
      destinationLat.text = point.latitude.toStringAsFixed(6);
      destinationLng.text = point.longitude.toStringAsFixed(6);
      estimate = null;
      routePoints = const [];
      addressResults = const [];
    });
  }

  Future<void> searchDestination() async {
    if (destinationAddress.text.trim().length < 3) {
      _message(context, 'Type at least three letters of the address.');
      return;
    }
    setState(() => searchingAddress = true);
    try {
      final results = await mapping.searchAddress(destinationAddress.text);
      if (mounted) setState(() => addressResults = results);
    } catch (error) {
      if (mounted) _message(context, error);
    } finally {
      if (mounted) setState(() => searchingAddress = false);
    }
  }

  void selectAddress(GeoPoint result) {
    setState(() {
      destinationAddress.text = result.label ?? '';
      destinationLat.text = result.latitude.toStringAsFixed(6);
      destinationLng.text = result.longitude.toStringAsFixed(6);
      addressResults = const [];
      estimate = null;
      routePoints = const [];
    });
  }

  Future<void> calculate() async {
    if (pickup == null) {
      await locate();
      if (pickup == null) return;
    }
    try {
      final destination = GeoPoint(
        double.parse(destinationLat.text),
        double.parse(destinationLng.text),
        label: destinationAddress.text.trim(),
      );
      final route = await mapping.route(pickup!, destination);
      final roadDistance = route.distanceKm;
      final minutes = route.durationMinutes;
      final fare = await widget.backend.estimateFare(
        distanceKm: roadDistance,
        durationMinutes: minutes,
      );
      setState(() {
        estimate = fare;
        distance = roadDistance;
        duration = minutes;
        routePoints = route.points;
      });
    } catch (error) {
      if (mounted) _message(context, error);
    }
  }

  Future<void> request() async {
    if (estimate == null || distance == null || duration == null) return;
    setState(() => busy = true);
    try {
      final id = await widget.backend.requestRide(
        pickup: pickup!,
        destination: GeoPoint(
          double.parse(destinationLat.text),
          double.parse(destinationLng.text),
          label: destinationAddress.text.trim(),
        ),
        distanceKm: distance!,
        durationMinutes: duration!,
        paymentMethod: paymentMethod,
      );
      if (mounted) _message(context, 'Ride requested: ${id.substring(0, 8)}');
    } catch (error) {
      if (mounted) _message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Book a ride', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.my_location),
                  title: Text(pickup == null
                      ? 'Pickup not selected'
                      : '${pickup!.latitude.toStringAsFixed(5)}, ${pickup!.longitude.toStringAsFixed(5)}'),
                  trailing: FilledButton.tonal(
                    onPressed: locate,
                    child: const Text('Use GPS'),
                  ),
                ),
                SizedBox(
                  height: 280,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: FlutterMap(
                      options: MapOptions(
                        initialCenter: map.LatLng(
                          pickup?.latitude ?? -26.2041,
                          pickup?.longitude ?? 28.0473,
                        ),
                        initialZoom: 11,
                        onTap: (_, point) => chooseDestination(point),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName:
                              'za.co.requestride.request_ride',
                        ),
                        if (routePoints.isNotEmpty)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: routePoints
                                    .map((point) => map.LatLng(
                                          point.latitude,
                                          point.longitude,
                                        ))
                                    .toList(),
                                strokeWidth: 5,
                                color: const Color(0xFF00D69A),
                              ),
                            ],
                          ),
                        MarkerLayer(markers: [
                          if (pickup != null)
                            Marker(
                              point: map.LatLng(
                                pickup!.latitude,
                                pickup!.longitude,
                              ),
                              child: const Icon(
                                Icons.my_location,
                                color: Colors.green,
                                size: 36,
                              ),
                            ),
                          Marker(
                            point: map.LatLng(
                              double.tryParse(destinationLat.text) ?? -26.1076,
                              double.tryParse(destinationLng.text) ?? 28.0567,
                            ),
                            child: const Icon(
                              Icons.location_pin,
                              color: Colors.red,
                              size: 42,
                            ),
                          ),
                          for (final driver in onlineDrivers)
                            Marker(
                              point: map.LatLng(
                                (driver['latitude'] as num).toDouble(),
                                (driver['longitude'] as num).toDouble(),
                              ),
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Color(0xFF031B1A),
                                  shape: BoxShape.circle,
                                ),
                                child: Padding(
                                  padding: EdgeInsets.all(6),
                                  child: Icon(
                                    Icons.local_taxi,
                                    color: Color(0xFF00D69A),
                                    size: 28,
                                  ),
                                ),
                              ),
                            ),
                        ]),
                        const RichAttributionWidget(
                          attributions: [
                            TextSourceAttribution('OpenStreetMap contributors'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('Tap the map to mark your destination.'),
                ),
                TextField(
                  controller: destinationAddress,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => searchDestination(),
                  decoration: InputDecoration(
                    labelText: 'Search destination address',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      tooltip: 'Search address',
                      onPressed: searchingAddress ? null : searchDestination,
                      icon: searchingAddress
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_forward),
                    ),
                  ),
                ),
                if (addressResults.isNotEmpty)
                  Card(
                    child: Column(
                      children: addressResults
                          .map((result) => ListTile(
                                leading: const Icon(Icons.location_on_outlined),
                                title: Text(result.label ?? 'Address'),
                                onTap: () => selectAddress(result),
                              ))
                          .toList(),
                    ),
                  ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: destinationLat,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Latitude'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: destinationLng,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Longitude'),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: calculate,
                  icon: const Icon(Icons.calculate),
                  label: const Text('Estimate fare'),
                ),
                if (estimate != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'R${estimate!.amount.toStringAsFixed(2)} · ${distance!.toStringAsFixed(1)} km · about $duration min',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'cash',
                        icon: Icon(Icons.payments_outlined),
                        label: Text('Cash'),
                      ),
                      ButtonSegment(
                        value: 'card',
                        icon: Icon(Icons.credit_card),
                        label: Text('Card'),
                      ),
                    ],
                    selected: {paymentMethod},
                    onSelectionChanged: (value) =>
                        setState(() => paymentMethod = value.first),
                  ),
                  if (paymentMethod == 'card')
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Card payment will remain pending until a payment provider is connected. Never enter card details directly into this app.',
                      ),
                    ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: busy ? null : request,
                    icon: const Icon(Icons.local_taxi),
                    label: Text(busy ? 'Requesting…' : 'Request ride'),
                  ),
                ],
              ]),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Available drivers',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Refresh drivers',
                onPressed:
                    pickup == null || loadingDrivers ? null : loadOnlineDrivers,
                icon: loadingDrivers
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          if (pickup == null)
            const Card(
              child: ListTile(
                leading: Icon(Icons.my_location),
                title: Text('Choose your pickup location'),
                subtitle: Text(
                  'Use GPS to find online drivers and calculate their distance.',
                ),
              ),
            )
          else if (driverLoadError != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: const Text('Could not check available drivers'),
                subtitle: Text(driverLoadError!),
              ),
            )
          else if (!loadingDrivers && onlineDrivers.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.local_taxi_outlined),
                title: Text('No drivers are available right now'),
                subtitle: Text(
                  'There are no approved drivers online near or far. Please try again shortly.',
                ),
              ),
            )
          else ...[
            if (onlineDrivers.isNotEmpty &&
                (onlineDrivers.first['distance_km'] as num).toDouble() > 10)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  'No drivers are close by. Showing the nearest online drivers farther away.',
                ),
              ),
            for (final driver in onlineDrivers)
              Card(
                child: ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.local_taxi)),
                  title: Text('${driver['full_name']}'),
                  subtitle: Text(
                    '${driver['vehicle_colour']} ${driver['vehicle_make']} ${driver['vehicle_model']} · ${driver['number_plate']}',
                  ),
                  trailing: Text(
                    '${(driver['distance_km'] as num).toDouble().toStringAsFixed(1)} km',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
          ],
          const SizedBox(height: 18),
          Text('Your trips', style: Theme.of(context).textTheme.titleLarge),
          StreamBuilder<List<Ride>>(
            stream: widget.backend.rides(),
            builder: (context, snapshot) {
              final rides = snapshot.data ?? [];
              if (rides.isEmpty) {
                return const ListTile(title: Text('No trips yet'));
              }
              return Column(
                children: rides
                    .map((ride) => _isLiveRide(ride.status)
                        ? _CustomerLiveRideCard(
                            backend: widget.backend,
                            ride: ride,
                          )
                        : _TripSummaryCard(
                            backend: widget.backend,
                            ride: ride,
                          ))
                    .toList(),
              );
            },
          ),
          _NotificationInbox(backend: widget.backend),
        ],
      );
}

bool _isLiveRide(RideStatus status) => switch (status) {
      RideStatus.accepted ||
      RideStatus.driverArriving ||
      RideStatus.driverArrived ||
      RideStatus.inProgress =>
        true,
      _ => false,
    };

String _rideStatusLabel(RideStatus status) => switch (status) {
      RideStatus.searching => 'Finding a driver',
      RideStatus.accepted => 'Driver accepted your ride',
      RideStatus.driverArriving => 'Driver is coming to collect you',
      RideStatus.driverArrived => 'Driver has arrived',
      RideStatus.inProgress => 'Travelling to your destination',
      RideStatus.completed => 'Trip completed',
      RideStatus.cancelled => 'Trip cancelled',
    };

class _CustomerLiveRideCard extends StatelessWidget {
  const _CustomerLiveRideCard({required this.backend, required this.ride});

  final Backend backend;
  final Ride ride;

  @override
  Widget build(BuildContext context) => StreamBuilder<Map<String, dynamic>?>(
        stream: backend.trackRide(ride.id),
        builder: (context, snapshot) {
          final tracking = snapshot.data;
          final driver = tracking == null
              ? null
              : GeoPoint(
                  (tracking['latitude'] as num).toDouble(),
                  (tracking['longitude'] as num).toDouble(),
                );
          final target = ride.status == RideStatus.inProgress
              ? ride.destination
              : ride.pickup;
          final distanceToTarget =
              driver == null ? null : _distanceKm(driver, target);
          final etaMinutes = distanceToTarget == null
              ? null
              : math.max(1, (distanceToTarget / 30 * 60).round());
          final centre = driver == null
              ? target
              : GeoPoint(
                  (driver.latitude + target.latitude) / 2,
                  (driver.longitude + target.longitude) / 2,
                );

          return Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.local_taxi)),
                  title: Text(_rideStatusLabel(ride.status)),
                  subtitle: Text(driver == null
                      ? 'Waiting for the driver\'s first location update…'
                      : '${distanceToTarget!.toStringAsFixed(1)} km away · about $etaMinutes min'),
                  trailing: Text(ride.estimatedFare == null
                      ? ''
                      : 'R${ride.estimatedFare!.toStringAsFixed(2)}'),
                ),
                SizedBox(
                  height: 300,
                  child: FlutterMap(
                    key: ValueKey(
                      '${ride.id}-${driver?.latitude}-${driver?.longitude}',
                    ),
                    options: MapOptions(
                      initialCenter: map.LatLng(
                        centre.latitude,
                        centre.longitude,
                      ),
                      initialZoom: _trackingZoom(distanceToTarget),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'za.co.requestride.request_ride',
                      ),
                      if (driver != null)
                        PolylineLayer(
                          polylines: [
                            Polyline(
                              points: [
                                map.LatLng(driver.latitude, driver.longitude),
                                map.LatLng(target.latitude, target.longitude),
                              ],
                              strokeWidth: 5,
                              color: const Color(0xFF00D69A),
                            ),
                          ],
                        ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: map.LatLng(
                              ride.pickup.latitude,
                              ride.pickup.longitude,
                            ),
                            child: const Icon(
                              Icons.person_pin_circle,
                              color: Color(0xFFFFC857),
                              size: 42,
                            ),
                          ),
                          Marker(
                            point: map.LatLng(
                              ride.destination.latitude,
                              ride.destination.longitude,
                            ),
                            child: const Icon(
                              Icons.flag_circle,
                              color: Color(0xFFFF5E5B),
                              size: 40,
                            ),
                          ),
                          if (driver != null)
                            Marker(
                              point: map.LatLng(
                                driver.latitude,
                                driver.longitude,
                              ),
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Color(0xFF031B1A),
                                  shape: BoxShape.circle,
                                ),
                                child: Padding(
                                  padding: EdgeInsets.all(7),
                                  child: Icon(
                                    Icons.local_taxi,
                                    color: Color(0xFF00D69A),
                                    size: 30,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const RichAttributionWidget(
                        attributions: [
                          TextSourceAttribution('OpenStreetMap contributors'),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Row(
                    children: [
                      const Icon(Icons.sync, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(driver == null
                            ? 'Live tracking will begin automatically.'
                            : 'Driver location updates automatically.'),
                      ),
                      if (ride.status != RideStatus.inProgress)
                        TextButton.icon(
                          onPressed: () =>
                              _cancelRideDialog(context, backend, ride),
                          icon: const Icon(Icons.cancel_outlined),
                          label: const Text('Cancel'),
                        ),
                      IconButton(
                        tooltip: 'Trip safety',
                        onPressed: () => _safetyDialog(context, backend, ride),
                        icon: const Icon(Icons.shield_outlined),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      );
}

double _trackingZoom(double? distanceKm) {
  if (distanceKm == null || distanceKm < 2) return 14;
  if (distanceKm < 5) return 12.5;
  if (distanceKm < 15) return 11;
  if (distanceKm < 40) return 9.5;
  return 8;
}

class DriverWorkspace extends StatefulWidget {
  const DriverWorkspace({required this.backend, super.key});
  final Backend backend;
  @override
  State<DriverWorkspace> createState() => _DriverWorkspaceState();
}

class _DriverWorkspaceState extends State<DriverWorkspace> {
  final make = TextEditingController();
  final model = TextEditingController();
  final year = TextEditingController(text: '${DateTime.now().year}');
  final colour = TextEditingController();
  final plate = TextEditingController();
  final address = TextEditingController();
  String bodyType = 'sedan';
  Map<String, Map<String, dynamic>> uploadedDocuments = {};
  var online = false;
  var busy = false;
  Map<String, dynamic>? application;
  StreamSubscription<Position>? positionUpdates;
  StreamSubscription<List<Ride>>? rideUpdates;
  Timer? locationHeartbeat;
  GeoPoint? lastLocation;
  String? activeRideId;
  var changingAvailability = false;

  static const documentTypes = {
    'drivers_licence': 'Driver licence',
    'professional_driving_permit': 'Professional driving permit',
    'vehicle_registration': 'Vehicle registration',
    'roadworthy': 'Roadworthy certificate',
    'insurance': 'Vehicle insurance',
    'proof_of_address': 'Proof of address',
    'identity_document': 'Identity document',
  };
  static const expiringDocuments = {
    'drivers_licence',
    'professional_driving_permit',
    'roadworthy',
    'insurance',
  };
  static const bodyTypes = {
    'sedan': 'Sedan',
    'hatchback': 'Hatchback',
    'suv': 'SUV',
    'mpv': 'MPV / people carrier',
    'coupe': 'Coupe',
    'station_wagon': 'Station wagon',
  };

  @override
  void initState() {
    super.initState();
    refresh();
    rideUpdates = widget.backend.rides().listen((rides) {
      final userId = widget.backend.currentUser?.id;
      activeRideId = rides
          .where((ride) => ride.driverId == userId && _isLiveRide(ride.status))
          .map((ride) => ride.id)
          .firstOrNull;
    });
  }

  @override
  void dispose() {
    positionUpdates?.cancel();
    rideUpdates?.cancel();
    locationHeartbeat?.cancel();
    if (online) unawaited(widget.backend.setDriverOnline(false, null));
    make.dispose();
    model.dispose();
    year.dispose();
    colour.dispose();
    plate.dispose();
    address.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    final value = await widget.backend.driverApplication();
    final user = widget.backend.currentUser;
    final documents = user == null
        ? const <Map<String, dynamic>>[]
        : await widget.backend.driverDocuments(user.id);
    if (mounted) {
      setState(() {
        application = value;
        uploadedDocuments = {
          for (final document in documents)
            document['type'] as String: document,
        };
      });
    }
  }

  Future<void> setAvailability(bool value) async {
    if (changingAvailability) return;
    setState(() => changingAvailability = true);
    try {
      if (!value) {
        await positionUpdates?.cancel();
        positionUpdates = null;
        locationHeartbeat?.cancel();
        locationHeartbeat = null;
        await widget.backend.setDriverOnline(false, null);
        if (mounted) setState(() => online = false);
        return;
      }

      final point = await _currentPoint();
      lastLocation = point;
      await widget.backend.setDriverOnline(true, point);
      if (mounted) setState(() => online = true);

      positionUpdates = Geolocator.getPositionStream(
        locationSettings: _driverLocationSettings(),
      ).listen((position) {
        final updated = GeoPoint(position.latitude, position.longitude);
        lastLocation = updated;
        unawaited(widget.backend.updateDriverLocation(
          updated,
          rideId: activeRideId,
        ));
      });
      locationHeartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
        final current = lastLocation;
        if (current != null && online) {
          unawaited(widget.backend.updateDriverLocation(
            current,
            rideId: activeRideId,
          ));
        }
      });
    } catch (error) {
      if (mounted) _message(context, error);
    } finally {
      if (mounted) setState(() => changingAvailability = false);
    }
  }

  Future<void> upload(String type) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
      withData: true,
    );
    final file = result?.files.single;
    if (file?.bytes == null) return;
    if (file!.size > 10 * 1024 * 1024) {
      if (mounted) _message(context, 'The file must be smaller than 10 MB.');
      return;
    }
    final extension = file.extension?.toLowerCase();
    final mimeType = switch (extension) {
      'pdf' => 'application/pdf',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      _ => '',
    };
    DateTime? expiresAt;
    if (expiringDocuments.contains(type) && mounted) {
      expiresAt = await showDatePicker(
        context: context,
        firstDate: DateTime.now().add(const Duration(days: 1)),
        lastDate: DateTime.now().add(const Duration(days: 3650)),
        helpText: 'Select document expiry date',
      );
      if (expiresAt == null) {
        if (mounted) _message(context, 'An expiry date is required.');
        return;
      }
    }
    try {
      await widget.backend.uploadDriverDocument(
        type: type,
        fileName: file.name,
        bytes: file.bytes!,
        mimeType: mimeType,
        expiresAt: expiresAt,
      );
      await refresh();
      if (mounted) _message(context, '${documentTypes[type]} uploaded');
    } catch (error) {
      if (mounted) _message(context, error);
    }
  }

  Future<void> submit() async {
    final values = [
      make.text,
      model.text,
      colour.text,
      plate.text,
      address.text
    ];
    if (values.any((value) => value.trim().isEmpty) ||
        address.text.trim().length < 8) {
      _message(context, 'Complete every vehicle and address field.');
      return;
    }
    final vehicleYear = int.tryParse(year.text);
    if (vehicleYear == null ||
        vehicleYear < 2000 ||
        vehicleYear > DateTime.now().year + 1) {
      _message(context, 'Enter a valid vehicle year from 2000 onwards.');
      return;
    }
    if (!documentTypes.keys.every(uploadedDocuments.containsKey)) {
      _message(context, 'Upload all seven required documents first.');
      return;
    }
    setState(() => busy = true);
    try {
      await widget.backend.saveVehicle(
        make: make.text.trim(),
        model: model.text.trim(),
        year: vehicleYear,
        colour: colour.text.trim(),
        numberPlate: plate.text.trim(),
        bodyType: bodyType,
      );
      await widget.backend.submitDriverApplication(address.text.trim());
      await refresh();
      if (mounted) _message(context, 'Application submitted for review');
    } catch (error) {
      if (mounted) _message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> accept(Ride ride) async {
    try {
      await widget.backend.acceptRide(ride.id);
      if (mounted) _message(context, 'Ride accepted');
    } catch (error) {
      if (mounted) _message(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = application?['status'] ?? 'draft';
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          child: SwitchListTile(
            secondary: Icon(online ? Icons.online_prediction : Icons.cloud_off),
            title: Text(online ? 'Online' : 'Offline'),
            subtitle: Text(status == 'approved'
                ? 'Approved to receive ride requests'
                : 'Application status: $status'),
            value: online,
            onChanged: status == 'approved' && !changingAvailability
                ? setAvailability
                : null,
          ),
        ),
        if (status != 'approved') ...[
          const SizedBox(height: 12),
          ExpansionTile(
            initiallyExpanded: true,
            title: const Text('Driver application'),
            subtitle: const Text('Cars only — bakkies are not accepted'),
            children: [
              for (final field in [
                (make, 'Vehicle make'),
                (model, 'Vehicle model'),
                (year, 'Year'),
                (colour, 'Colour'),
                (plate, 'Number plate'),
                (address, 'Residential address'),
              ])
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: TextField(
                    controller: field.$1,
                    decoration: InputDecoration(labelText: field.$2),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: DropdownButtonFormField<String>(
                  initialValue: bodyType,
                  decoration: const InputDecoration(labelText: 'Car body type'),
                  items: bodyTypes.entries
                      .map((entry) => DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ))
                      .toList(),
                  onChanged: (value) => setState(() => bodyType = value!),
                ),
              ),
              for (final entry in documentTypes.entries)
                ListTile(
                  leading: Icon(uploadedDocuments.containsKey(entry.key)
                      ? Icons.check_circle
                      : Icons.upload_file),
                  title: Text(entry.value),
                  subtitle: uploadedDocuments.containsKey(entry.key)
                      ? Text(
                          'Uploaded${uploadedDocuments[entry.key]?['expires_at'] == null ? '' : ' · expires ${uploadedDocuments[entry.key]?['expires_at']}'}',
                        )
                      : Text(expiringDocuments.contains(entry.key)
                          ? 'PDF/JPG/PNG · expiry date required'
                          : 'PDF/JPG/PNG · maximum 10 MB'),
                  trailing: TextButton(
                    onPressed: () => upload(entry.key),
                    child: const Text('Upload'),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: busy || status == 'pending' ? null : submit,
                  child: Text(status == 'pending'
                      ? 'Awaiting review'
                      : 'Submit application'),
                ),
              ),
            ],
          ),
        ],
        if (status == 'approved') ...[
          Text('Available requests',
              style: Theme.of(context).textTheme.titleLarge),
          StreamBuilder<List<Ride>>(
            stream: widget.backend.availableRideRequestsStream(),
            builder: (context, snapshot) => Column(
              children: (snapshot.data ?? [])
                  .map((ride) => Card(
                        child: ListTile(
                          title: Text(ride.destination.label ?? 'Ride request'),
                          subtitle: Text(
                              'Estimated R${ride.estimatedFare?.toStringAsFixed(2)}'),
                          trailing: FilledButton(
                            onPressed: online ? () => accept(ride) : null,
                            child: const Text('Accept'),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
          Text('Your trips', style: Theme.of(context).textTheme.titleLarge),
          StreamBuilder<List<Ride>>(
            stream: widget.backend.rides(),
            builder: (context, snapshot) => Column(
              children: (snapshot.data ?? [])
                  .where(
                      (ride) => ride.driverId == widget.backend.currentUser?.id)
                  .map((ride) =>
                      _DriverRideCard(backend: widget.backend, ride: ride))
                  .toList(),
            ),
          ),
          _NotificationInbox(backend: widget.backend),
        ],
      ],
    );
  }
}

class _NotificationInbox extends StatelessWidget {
  const _NotificationInbox({required this.backend});
  final Backend backend;

  @override
  Widget build(BuildContext context) =>
      StreamBuilder<List<Map<String, dynamic>>>(
        stream: backend.notifications(),
        builder: (context, snapshot) {
          final unread = (snapshot.data ?? const [])
              .where((notification) => notification['read_at'] == null)
              .toList();
          if (unread.isEmpty) return const SizedBox.shrink();
          return Card(
            child: ExpansionTile(
              leading: Badge(
                label: Text('${unread.length}'),
                child: const Icon(Icons.notifications_active),
              ),
              title: const Text('New notifications'),
              children: unread
                  .take(5)
                  .map((notification) => ListTile(
                        title: Text('${notification['title']}'),
                        subtitle: Text('${notification['body']}'),
                        trailing: IconButton(
                          tooltip: 'Mark as read',
                          onPressed: () => backend.markNotificationRead(
                            notification['id'] as String,
                          ),
                          icon: const Icon(Icons.done),
                        ),
                      ))
                  .toList(),
            ),
          );
        },
      );
}

class _DriverRideCard extends StatelessWidget {
  const _DriverRideCard({required this.backend, required this.ride});
  final Backend backend;
  final Ride ride;

  RideStatus? get next => switch (ride.status) {
        RideStatus.accepted => RideStatus.driverArriving,
        RideStatus.driverArriving => RideStatus.driverArrived,
        RideStatus.driverArrived => RideStatus.inProgress,
        RideStatus.inProgress => RideStatus.completed,
        _ => null,
      };

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.local_taxi),
                title: Text(ride.destination.label ?? 'Trip'),
                subtitle: Text(_rideStatusLabel(ride.status)),
                trailing: Text(
                  'R${(ride.finalFare ?? ride.estimatedFare ?? 0).toStringAsFixed(2)}',
                ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _showTripDetails(context, backend, ride),
                    icon: const Icon(Icons.receipt_long),
                    label: const Text('Details'),
                  ),
                  if (next != null)
                    FilledButton.tonal(
                      onPressed: () async {
                        try {
                          final point = await _currentPoint();
                          await backend.updateDriverLocation(point,
                              rideId: ride.id);
                          await backend.transitionRide(ride.id, next!);
                        } catch (error) {
                          if (context.mounted) _message(context, error);
                        }
                      },
                      child: Text(_nextStatusLabel(next!)),
                    ),
                  if (ride.status == RideStatus.accepted ||
                      ride.status == RideStatus.driverArriving ||
                      ride.status == RideStatus.driverArrived)
                    TextButton.icon(
                      onPressed: () =>
                          _cancelRideDialog(context, backend, ride),
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Cancel'),
                    ),
                  if (ride.status == RideStatus.completed)
                    FilledButton.tonalIcon(
                      onPressed: () => _rateRideDialog(context, backend, ride),
                      icon: const Icon(Icons.star),
                      label: const Text('Rate customer'),
                    ),
                  if (_isLiveRide(ride.status))
                    OutlinedButton.icon(
                      onPressed: () => _safetyDialog(context, backend, ride),
                      icon: const Icon(Icons.shield_outlined),
                      label: const Text('Safety'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
}

String _nextStatusLabel(RideStatus status) => switch (status) {
      RideStatus.driverArriving => 'Navigate to pickup',
      RideStatus.driverArrived => 'Mark arrived',
      RideStatus.inProgress => 'Start trip',
      RideStatus.completed => 'Complete trip',
      _ => status.name,
    };

class _TripSummaryCard extends StatelessWidget {
  const _TripSummaryCard({required this.backend, required this.ride});
  final Backend backend;
  final Ride ride;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: Icon(ride.status == RideStatus.completed
              ? Icons.check_circle
              : ride.status == RideStatus.cancelled
                  ? Icons.cancel
                  : Icons.route),
          title: Text(ride.destination.label?.isNotEmpty == true
              ? ride.destination.label!
              : 'Destination'),
          subtitle: Text(ride.cancellationReason == null
              ? _rideStatusLabel(ride.status)
              : '${_rideStatusLabel(ride.status)} · ${ride.cancellationReason}'),
          trailing: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            children: [
              Text(
                'R${(ride.finalFare ?? ride.estimatedFare ?? 0).toStringAsFixed(2)}',
              ),
              IconButton(
                tooltip: 'Trip details',
                onPressed: () => _showTripDetails(context, backend, ride),
                icon: const Icon(Icons.receipt_long),
              ),
              if (ride.status == RideStatus.searching)
                IconButton(
                  tooltip: 'Cancel ride',
                  onPressed: () => _cancelRideDialog(context, backend, ride),
                  icon: const Icon(Icons.cancel_outlined),
                ),
              if (ride.status == RideStatus.completed)
                IconButton(
                  tooltip: 'Rate driver',
                  onPressed: () => _rateRideDialog(context, backend, ride),
                  icon: const Icon(Icons.star_outline),
                ),
            ],
          ),
        ),
      );
}

Future<void> _rateRideDialog(
  BuildContext context,
  Backend backend,
  Ride ride,
) async {
  final existing = await backend.myRating(ride.id);
  if (!context.mounted) return;
  var score = (existing?['score'] as num?)?.toInt() ?? 5;
  final comment = TextEditingController(
    text: existing?['comment'] as String? ?? '',
  );
  final submit = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Rate this trip'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                5,
                (index) => IconButton(
                  onPressed: () => setDialogState(() => score = index + 1),
                  icon: Icon(index < score ? Icons.star : Icons.star_border),
                  color: const Color(0xFFFFC857),
                ),
              ),
            ),
            TextField(
              controller: comment,
              maxLength: 1000,
              maxLines: 3,
              decoration:
                  const InputDecoration(labelText: 'Comment (optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save rating'),
          ),
        ],
      ),
    ),
  );
  if (submit == true) {
    try {
      await backend.rateRide(ride.id, score, comment.text.trim());
      if (context.mounted) _message(context, 'Rating saved');
    } catch (error) {
      if (context.mounted) _message(context, error);
    }
  }
  comment.dispose();
}

Future<void> _showTripDetails(
  BuildContext context,
  Backend backend,
  Ride ride,
) async {
  try {
    final details = await backend.tripDetails(ride.id);
    if (!context.mounted) return;
    final vehicle = details['vehicles'] as Map<String, dynamic>?;
    final driver = details['profiles'] as Map<String, dynamic>?;
    final fare = details['fare_rules'] as Map<String, dynamic>?;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Trip receipt and details'),
        content: SizedBox(
          width: 560,
          child: ListView(
            shrinkWrap: true,
            children: [
              _ReviewDetail(
                  label: 'Status', value: _rideStatusLabel(ride.status)),
              _ReviewDetail(label: 'Pickup', value: ride.pickup.label),
              _ReviewDetail(
                  label: 'Destination', value: ride.destination.label),
              _ReviewDetail(label: 'Requested', value: ride.requestedAt),
              _ReviewDetail(label: 'Completed', value: ride.completedAt),
              _ReviewDetail(
                label: 'Distance',
                value: (ride.actualDistanceKm ?? ride.distanceKm) == null
                    ? null
                    : '${(ride.actualDistanceKm ?? ride.distanceKm)!.toStringAsFixed(1)} km',
              ),
              _ReviewDetail(
                label: 'Estimated time',
                value: (ride.actualDurationMinutes ?? ride.durationMinutes) ==
                        null
                    ? null
                    : '${ride.actualDurationMinutes ?? ride.durationMinutes} minutes',
              ),
              _ReviewDetail(label: 'Driver', value: driver?['full_name']),
              _ReviewDetail(
                label: 'Vehicle',
                value: vehicle == null
                    ? null
                    : '${vehicle['colour']} ${vehicle['make']} ${vehicle['model']} · ${vehicle['number_plate']}',
              ),
              _ReviewDetail(
                label: 'Fare',
                value:
                    'R${(ride.finalFare ?? ride.estimatedFare ?? 0).toStringAsFixed(2)}',
              ),
              _ReviewDetail(label: 'Fare rule', value: fare?['name']),
              _ReviewDetail(label: 'Payment method', value: ride.paymentMethod),
              _ReviewDetail(label: 'Payment status', value: ride.paymentStatus),
              if (ride.cancellationReason != null)
                _ReviewDetail(
                  label: 'Cancellation reason',
                  value: ride.cancellationReason,
                ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  } catch (error) {
    if (context.mounted) _message(context, error);
  }
}

Future<String?> _askAdminReason(BuildContext context, String title) async {
  final controller = TextEditingController();
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 500,
        maxLines: 3,
        decoration: const InputDecoration(
          labelText: 'Reason',
          hintText: 'Explain what the driver needs to correct',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final reason = controller.text.trim();
            if (reason.length >= 3) Navigator.pop(context, reason);
          },
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  controller.dispose();
  return value;
}

class AdminWorkspace extends StatefulWidget {
  const AdminWorkspace({required this.backend, super.key});
  final Backend backend;
  @override
  State<AdminWorkspace> createState() => _AdminWorkspaceState();
}

class _AdminWorkspaceState extends State<AdminWorkspace> {
  late Future<List<Map<String, dynamic>>> pending;
  late Future<List<Map<String, dynamic>>> fares;
  late Future<List<Map<String, dynamic>>> drivers;
  late Future<List<Map<String, dynamic>>> incidents;

  @override
  void initState() {
    super.initState();
    reload();
  }

  void reload() {
    pending = widget.backend.pendingDrivers();
    fares = widget.backend.activeFareRules();
    drivers = widget.backend.driverApplications();
    incidents = widget.backend.safetyIncidents();
  }

  Future<void> review(String id, bool approve, {String? reason}) async {
    try {
      await widget.backend.reviewDriver(id, approve, reason: reason);
      setState(reload);
      if (mounted) {
        _message(context, approve ? 'Driver approved' : 'Driver rejected');
      }
    } catch (error) {
      if (mounted) _message(context, error);
    }
  }

  Future<void> openReview(Map<String, dynamic> application) async {
    final decision = await showDialog<bool>(
      context: context,
      builder: (context) => _DriverReviewDialog(
        backend: widget.backend,
        application: application,
      ),
    );
    if (decision != null && mounted) {
      String? reason;
      if (!decision) {
        reason = await _askAdminReason(context, 'Reason for rejection');
        if (reason == null) return;
      }
      await review(application['driver_id'] as String, decision,
          reason: reason);
    }
  }

  Future<void> editFare(Map<String, dynamic>? current) async {
    final fields = {
      'Name':
          TextEditingController(text: '${current?['name'] ?? 'Standard rate'}'),
      'Base fare':
          TextEditingController(text: '${current?['base_fare'] ?? 12}'),
      'Per km': TextEditingController(text: '${current?['per_km'] ?? 8.5}'),
      'Per minute':
          TextEditingController(text: '${current?['per_minute'] ?? 1.2}'),
      'Minimum fare':
          TextEditingController(text: '${current?['minimum_fare'] ?? 35}'),
      'Booking fee':
          TextEditingController(text: '${current?['booking_fee'] ?? 3}'),
    };
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit active fare rule'),
        content: SizedBox(
          width: 480,
          child: ListView(
            shrinkWrap: true,
            children: fields.entries
                .map((entry) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: TextField(
                        controller: entry.value,
                        keyboardType: entry.key == 'Name'
                            ? TextInputType.text
                            : const TextInputType.numberWithOptions(
                                decimal: true),
                        decoration: InputDecoration(labelText: entry.key),
                      ),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Activate rates'),
          ),
        ],
      ),
    );
    if (save == true) {
      try {
        await widget.backend.setFareRule(
          name: fields['Name']!.text.trim(),
          base: double.parse(fields['Base fare']!.text),
          perKm: double.parse(fields['Per km']!.text),
          perMinute: double.parse(fields['Per minute']!.text),
          minimum: double.parse(fields['Minimum fare']!.text),
          booking: double.parse(fields['Booking fee']!.text),
        );
        setState(reload);
        if (mounted) _message(context, 'New fare rule activated');
      } catch (error) {
        if (mounted) _message(context, error);
      }
    }
    for (final controller in fields.values) {
      controller.dispose();
    }
  }

  Future<void> changeDriverStatus(
    Map<String, dynamic> driver,
    String status,
  ) async {
    var reason = '';
    if (status != 'approved') {
      final value = await _askAdminReason(
        context,
        status == 'suspended'
            ? 'Reason for suspension'
            : 'Reason for rejection',
      );
      if (value == null) return;
      reason = value;
    }
    try {
      await widget.backend.setDriverStatus(
        driver['driver_id'] as String,
        status,
        reason,
      );
      setState(reload);
      if (mounted) _message(context, 'Driver status updated');
    } catch (error) {
      if (mounted) _message(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Operations dashboard',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: pending,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.error_outline),
                    title: const Text('Could not load pending drivers'),
                    subtitle: Text('${snapshot.error}'),
                    trailing: IconButton(
                      tooltip: 'Try again',
                      onPressed: () => setState(reload),
                      icon: const Icon(Icons.refresh),
                    ),
                  ),
                );
              }
              final rows = snapshot.data ?? [];
              return Card(
                child: Column(children: [
                  ListTile(
                    leading: const Icon(Icons.fact_check),
                    title: const Text('Pending driver approvals'),
                    trailing: snapshot.connectionState ==
                            ConnectionState.waiting
                        ? const SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              CircleAvatar(child: Text('${rows.length}')),
                              IconButton(
                                tooltip: 'Refresh',
                                onPressed: () => setState(reload),
                                icon: const Icon(Icons.refresh),
                              ),
                            ],
                          ),
                  ),
                  for (final row in rows)
                    ListTile(
                      onTap: () => openReview(row),
                      title:
                          Text('${row['profiles']?['full_name'] ?? 'Driver'}'),
                      subtitle: Text(
                          '${row['vehicles']?['make'] ?? ''} ${row['vehicles']?['model'] ?? ''} · ${row['vehicles']?['number_plate'] ?? ''}'),
                      trailing: FilledButton.tonalIcon(
                        onPressed: () => openReview(row),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Review documents'),
                      ),
                    ),
                ]),
              );
            },
          ),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: fares,
            builder: (context, snapshot) {
              final rule = snapshot.data?.firstOrNull;
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.payments),
                  title: Text(rule?['name'] as String? ?? 'Fare rules'),
                  subtitle: rule == null
                      ? const Text('No active rule')
                      : Text(
                          'Base R${rule['base_fare']} · R${rule['per_km']}/km · R${rule['per_minute']}/min · minimum R${rule['minimum_fare']}'),
                  trailing: FilledButton.tonalIcon(
                    onPressed: () => editFare(rule),
                    icon: const Icon(Icons.edit),
                    label: const Text('Edit rates'),
                  ),
                ),
              );
            },
          ),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: drivers,
            builder: (context, snapshot) {
              final rows = snapshot.data ?? const [];
              return Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.local_taxi),
                  title: const Text('Driver management'),
                  subtitle: Text('${rows.length} driver applications'),
                  children: rows.map((driver) {
                    final profile = driver['profiles'] as Map<String, dynamic>?;
                    final vehicle = driver['vehicles'] as Map<String, dynamic>?;
                    final status = '${driver['status']}';
                    return ListTile(
                      title: Text('${profile?['full_name'] ?? 'Driver'}'),
                      subtitle: Text(
                        '$status · ${vehicle?['make'] ?? ''} ${vehicle?['model'] ?? ''} · ${vehicle?['number_plate'] ?? ''}',
                      ),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Change driver status',
                        onSelected: (value) =>
                            changeDriverStatus(driver, value),
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                              value: 'approved',
                              child: Text('Approve / restore')),
                          PopupMenuItem(
                              value: 'suspended', child: Text('Suspend')),
                          PopupMenuItem(
                              value: 'rejected', child: Text('Reject')),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: incidents,
            builder: (context, snapshot) {
              final rows = snapshot.data ?? const [];
              final open =
                  rows.where((row) => row['status'] != 'resolved').toList();
              return Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.health_and_safety),
                  title: const Text('Safety incidents'),
                  subtitle: Text('${open.length} require attention'),
                  children: open
                      .map((incident) => ListTile(
                            leading: const Icon(Icons.warning_amber),
                            title: Text(
                                '${incident['incident_type']}'.toUpperCase()),
                            subtitle: Text(
                              '${incident['profiles']?['full_name'] ?? 'User'} · ${incident['details'] ?? 'No details'} · ${incident['created_at']}',
                            ),
                          ))
                      .toList(),
                ),
              );
            },
          ),
          Card(
            child: StreamBuilder<List<Ride>>(
              stream: widget.backend.rides(),
              builder: (context, snapshot) {
                final rides = snapshot.data ?? const [];
                return ExpansionTile(
                  leading: const Icon(Icons.monitor_heart),
                  title: const Text('Trip operations'),
                  subtitle: const Text('Live and historical trip feed'),
                  trailing: CircleAvatar(child: Text('${rides.length}')),
                  children: rides
                      .map((ride) => ListTile(
                            title: Text(ride.destination.label ?? 'Trip'),
                            subtitle: Text(_rideStatusLabel(ride.status)),
                            trailing: IconButton(
                              tooltip: 'Open trip details',
                              onPressed: () => _showTripDetails(
                                context,
                                widget.backend,
                                ride,
                              ),
                              icon: const Icon(Icons.open_in_new),
                            ),
                          ))
                      .toList(),
                );
              },
            ),
          ),
        ],
      );
}

class _DriverReviewDialog extends StatefulWidget {
  const _DriverReviewDialog({
    required this.backend,
    required this.application,
  });

  final Backend backend;
  final Map<String, dynamic> application;

  @override
  State<_DriverReviewDialog> createState() => _DriverReviewDialogState();
}

class _DriverReviewDialogState extends State<_DriverReviewDialog> {
  static const labels = {
    'drivers_licence': 'Driver licence',
    'professional_driving_permit': 'Professional driving permit',
    'vehicle_registration': 'Vehicle registration',
    'roadworthy': 'Roadworthy certificate',
    'insurance': 'Vehicle insurance',
    'proof_of_address': 'Proof of address',
    'identity_document': 'Identity document',
  };

  late Future<List<Map<String, dynamic>>> documents;
  String? openingPath;

  @override
  void initState() {
    super.initState();
    documents = widget.backend.driverDocuments(
      widget.application['driver_id'] as String,
    );
  }

  Future<void> openDocument(Map<String, dynamic> document) async {
    final path = document['storage_path'] as String;
    setState(() => openingPath = path);
    try {
      final signedUrl = await widget.backend.driverDocumentUrl(path);
      if (!await launchUrl(
        Uri.parse(signedUrl),
        mode: LaunchMode.externalApplication,
      )) {
        throw Exception('No application could open this document.');
      }
    } catch (error) {
      if (mounted) _message(context, error);
    } finally {
      if (mounted) setState(() => openingPath = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.application['profiles'] as Map<String, dynamic>?;
    final vehicle = widget.application['vehicles'] as Map<String, dynamic>?;
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: documents,
      builder: (context, snapshot) {
        final rows = snapshot.data ?? [];
        final uploadedTypes = rows.map((row) => row['type']).toSet();
        final complete = labels.keys.every(uploadedTypes.contains);
        return AlertDialog(
          title: Text('Review ${profile?['full_name'] ?? 'driver'}'),
          content: SizedBox(
            width: 720,
            height: 560,
            child: ListView(
              children: [
                Text(
                  'Driver application',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                _ReviewDetail(label: 'Full name', value: profile?['full_name']),
                _ReviewDetail(label: 'Phone', value: profile?['phone']),
                _ReviewDetail(
                  label: 'Residential address',
                  value: widget.application['proof_of_address_text'],
                ),
                _ReviewDetail(
                  label: 'Vehicle',
                  value:
                      '${vehicle?['year'] ?? ''} ${vehicle?['make'] ?? ''} ${vehicle?['model'] ?? ''}',
                ),
                _ReviewDetail(label: 'Colour', value: vehicle?['colour']),
                _ReviewDetail(
                  label: 'Number plate',
                  value: vehicle?['number_plate'],
                ),
                const SizedBox(height: 16),
                Text(
                  'Uploaded documents (${rows.length}/${labels.length})',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  )
                else if (snapshot.hasError)
                  ListTile(
                    leading: const Icon(Icons.error_outline),
                    title: const Text('Could not load documents'),
                    subtitle: Text('${snapshot.error}'),
                    trailing: IconButton(
                      onPressed: () => setState(() {
                        documents = widget.backend.driverDocuments(
                          widget.application['driver_id'] as String,
                        );
                      }),
                      icon: const Icon(Icons.refresh),
                    ),
                  )
                else
                  for (final entry in labels.entries)
                    Builder(builder: (context) {
                      final matches = rows
                          .where((row) => row['type'] == entry.key)
                          .toList();
                      final document = matches.firstOrNull;
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            document == null
                                ? Icons.warning_amber
                                : Icons.description,
                          ),
                          title: Text(entry.value),
                          subtitle: Text(
                            document == null
                                ? 'Not uploaded'
                                : 'Ready to review',
                          ),
                          trailing: document == null
                              ? null
                              : OutlinedButton.icon(
                                  onPressed:
                                      openingPath == document['storage_path']
                                          ? null
                                          : () => openDocument(document),
                                  icon: const Icon(Icons.open_in_new),
                                  label: const Text('Open'),
                                ),
                        ),
                      );
                    }),
                if (!complete && !snapshot.hasError)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text(
                      'Approval is disabled until all required documents are uploaded.',
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            TextButton.icon(
              onPressed:
                  snapshot.hasData ? () => Navigator.pop(context, false) : null,
              icon: const Icon(Icons.close),
              label: const Text('Reject'),
            ),
            FilledButton.icon(
              onPressed: snapshot.hasData && complete
                  ? () => Navigator.pop(context, true)
                  : null,
              icon: const Icon(Icons.check),
              label: const Text('Approve'),
            ),
          ],
        );
      },
    );
  }
}

class _ReviewDetail extends StatelessWidget {
  const _ReviewDetail({required this.label, required this.value});

  final String label;
  final Object? value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 150,
              child: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Expanded(child: Text('${value ?? 'Not provided'}')),
          ],
        ),
      );
}
