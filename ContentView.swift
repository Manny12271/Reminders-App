import SwiftUI
import CoreLocation
import MapKit
import UserNotifications

// MARK: - Reminder Model
struct Reminder: Identifiable, Codable, Equatable {
    let id: UUID
    var task: String
    var address: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Location Manager
class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var monitoredReminders: [Reminder] = []

    @Published var reminders: [Reminder] = [] {
        didSet {
            saveReminders()
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        loadReminders()
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func addReminder(task: String, address: String) {
        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(address) { [weak self] placemarks, error in
            guard let placemark = placemarks?.first,
                  let location = placemark.location else {
                print("Failed to find location for address")
                return
            }

            let reminder = Reminder(id: UUID(), task: task, address: address, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            DispatchQueue.main.async {
                self?.reminders.append(reminder)
                self?.monitoredReminders.append(reminder)
                self?.manager.startUpdatingLocation()
                self?.triggerReminder(reminder)
            }
        }
    }

    func updateReminder(_ updated: Reminder) {
        if let index = reminders.firstIndex(where: { $0.id == updated.id }) {
            reminders[index] = updated
            monitoredReminders.append(updated)
            manager.startUpdatingLocation()
            triggerReminder(updated)
        }
    }

    func deleteReminder(_ reminder: Reminder) {
        reminders.removeAll { $0.id == reminder.id }
        monitoredReminders.removeAll { $0.id == reminder.id }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let current = locations.first else { return }

        for (index, reminder) in monitoredReminders.enumerated().reversed() {
            let target = CLLocation(latitude: reminder.latitude, longitude: reminder.longitude)
            let distance = current.distance(from: target)

            if distance < 100 {
                triggerReminder(reminder)
                monitoredReminders.remove(at: index)
            }
        }
    }

    private func triggerReminder(_ reminder: Reminder) {
        let content = UNMutableNotificationContent()
        content.title = "Location Reminder"
        content.body = reminder.task
        content.sound = UNNotificationSound.default

        let center = CLLocationCoordinate2D(latitude: reminder.latitude, longitude: reminder.longitude)
        let region = CLCircularRegion(center: center, radius: 100, identifier: reminder.id.uuidString)
        region.notifyOnEntry = true
        region.notifyOnExit = false

        let trigger = UNLocationNotificationTrigger(region: region, repeats: false)

        let request = UNNotificationRequest(identifier: reminder.id.uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling location notification: \(error)")
            }
        }
    }

    private let storageKey = "reminders"

    private func saveReminders() {
        if let data = try? JSONEncoder().encode(reminders) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadReminders() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([Reminder].self, from: data) {
            reminders = saved
            monitoredReminders = saved
        }
    }
}

// MARK: - Map View
struct SimpleMapView: View {
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        Map(position: .constant(.region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )))) {
            Marker("Reminder", coordinate: coordinate)
        }
        .frame(height: 150)
        .cornerRadius(10)
        .onTapGesture {
            let url = URL(string: "http://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)")!
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Edit Reminder View
struct EditReminderView: View {
    @Binding var reminder: Reminder
    var onSave: (Reminder) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                TextField("Task", text: $reminder.task)
                TextField("Address", text: $reminder.address)
            }
            .navigationTitle("Edit Reminder")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onSave(reminder)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Reminder Detail View
struct ReminderDetailView: View {
    @Binding var reminder: Reminder
    var onDelete: () -> Void
    var onUpdate: (Reminder) -> Void
    @State private var showEdit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(reminder.task)
                .font(.largeTitle)
                .bold()

            Text(reminder.address)
                .font(.subheadline)

            SimpleMapView(coordinate: reminder.coordinate)

            Spacer()
        }
        .padding()
        .navigationTitle("Reminder")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: {
                    showEdit = true
                }) {
                    Image(systemName: "pencil")
                }

                Button(role: .destructive, action: {
                    onDelete()
                }) {
                    Image(systemName: "trash")
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            EditReminderView(reminder: $reminder) { updated in
                reminder = updated
                onUpdate(updated)
            }
        }
    }
}

// MARK: - Reminder List View
struct ReminderListView: View {
    @ObservedObject var locationManager: LocationManager
    @State private var selectedReminder: Reminder?
    @State private var newTask = ""
    @State private var newAddress = ""

    var body: some View {
        VStack {
            Form {
                Section(header: Text("New Reminder")) {
                    TextField("Task", text: $newTask)
                    TextField("Address", text: $newAddress)
                    Button("Add Reminder") {
                        locationManager.addReminder(task: newTask, address: newAddress)
                        newTask = ""
                        newAddress = ""
                    }
                }

                Section(header: Text("Reminders")) {
                    ForEach(locationManager.reminders) { reminder in
                        NavigationLink(destination:
                            ReminderDetailView(
                                reminder: Binding(
                                    get: { reminder },
                                    set: { updated in
                                        if let index = locationManager.reminders.firstIndex(of: reminder) {
                                            locationManager.updateReminder(updated)
                                        }
                                    }
                                ),
                                onDelete: {
                                    locationManager.deleteReminder(reminder)
                                },
                                onUpdate: { updated in
                                    locationManager.updateReminder(updated)
                                }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(reminder.task)
                                    .font(.headline)
                                Text(reminder.address)
                                SimpleMapView(coordinate: reminder.coordinate)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .navigationTitle("Location Reminders")
    }
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var locationManager = LocationManager()

    var body: some View {
        NavigationView {
            ReminderListView(locationManager: locationManager)
        }
        .onAppear {
            locationManager.requestAuthorization()
        }
    }
}

// MARK: - Main App Entry
@main
struct MyRemindersApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

