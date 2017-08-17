//
//  LocationService.swift
//
//  Copyright (c) 2017 OpenLocate
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import CoreLocation

protocol LocationServiceType {
    func start()
    func stop()
}

private let locationTimeInterval: TimeInterval = 120.0
private let locationsKey = "locations"

final class LocationService: LocationServiceType {

    private let locationManager: LocationManagerType
    private let httpClient: Postable
    private let tcpClient: Writeable
    private let locationDataSource: LocationDataSourceType
    private let logger: Logger
    private let loggerDataSource: LoggerDataSourceType?
    private let scheduler: Scheduler
    private var advertisingInfo: AdvertisingInfo

    private var url: String
    private var headers: Headers?

    private var lastKnownLocation: CLLocation?

    private var locationTask: Task?
    private var logTask: Task?

    init(
        postable: Postable,
        writeable: Writeable,
        locationDataSource: LocationDataSourceType,
        logger: Logger,
        scheduler: Scheduler,
        url: String,
        headers: Headers?,
        advertisingInfo: AdvertisingInfo,
        locationManager: LocationManagerType,
        loggerDataSource: LoggerDataSourceType? = nil) {

        httpClient = postable
        tcpClient = writeable
        self.locationDataSource = locationDataSource
        self.locationManager = locationManager
        self.logger = logger
        self.scheduler = scheduler
        self.loggerDataSource = loggerDataSource
        self.advertisingInfo = advertisingInfo
        self.url = url
        self.headers = headers
    }

    func start() {
        logger.info("Location service started for url : \(url)")
        schedule()

        locationManager.subscribe { location in

            if let lastLocation = self.lastKnownLocation,
                lastLocation.timestamp + locationTimeInterval > location.timestamp {
                return
            }
            self.lastKnownLocation = location

            let openLocateLocation = OpenLocateLocation(
                location: location,
                advertisingInfo: self.advertisingInfo
            )

            do {
                try self.locationDataSource.add(location: openLocateLocation)
            } catch let error {
                self.logger.error(
                    "Could not add location to database for url : \(self.url)." +
                    " Reason : \(error.localizedDescription)"
                )
                debugPrint(error.localizedDescription)
            }
            debugPrint(self.locationDataSource.count)
        }
    }

    func stop() {
        unschedule()
        locationManager.cancel()
    }
}

extension LocationService {
    private func schedule() {
        scheduleLocationDispatch()
        scheduleLogDispatch()
    }

    private func scheduleLocationDispatch() {
        locationTask = PeriodicTask.Builder()
            .set { _ in
                let indexedLocations = self.locationDataSource.popAll()
                let locations = indexedLocations.map { $1 }
                self.postLocations(locations: locations)
            }
            .build()
        scheduler.schedule(task: locationTask!)
    }

    private func scheduleLogDispatch() {
        logTask = PeriodicTask.Builder()
            .set { _ in
                guard let datasource = self.loggerDataSource else {
                    return
                }

                self.postLogs(datasource: datasource)
            }
            .build()
        scheduler.schedule(task: logTask!)
    }

    private func unschedule() {
        if let task = locationTask {
            scheduler.cancel(task: task)
        }

        if let task = logTask {
            scheduler.cancel(task: task)
        }
    }

    private func postLocations(locations: [OpenLocateLocationType]) {
        if locations.isEmpty {
            return
        }

        let params = [locationsKey: locations.map { $0.json }]
        do {
            try httpClient.post(
                params: params,
                url: url,
                additionalHeaders: headers,
                success: { _, _ in
            }
            ) { _, _ in
                self.locationDataSource.addAll(locations: locations)
                self.logger.error("failure in posting locations!!!")
            }
        } catch let error {
            logger.error(error.localizedDescription)
        }
    }

    private func postLogs(datasource: LoggerDataSourceType) {
        let logs = datasource.popAll()

        if logs.isEmpty {
            return
        }

        logs.forEach { log in
            do {
                try tcpClient.write(data: log.stringFormat) { _, response in
                    if response.error != nil {
                        datasource.add(log: log)
                    }
                }
            } catch let error {
                logger.error(error.localizedDescription)
            }
        }
    }
}

extension LocationService {
    static func isEnabled() -> Bool {
        return LocationManager.locationServicesEnabled()
    }

    static func isAuthorizationDenied() -> Bool {
        return LocationManager.isAuthorizationDenied()
    }

    static func isAuthorizationKeysValid() -> Bool {
        let always = Bundle.main.object(forInfoDictionaryKey: "NSLocationAlwaysUsageDescription")
        let inUse = Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription")
        return always != nil || inUse != nil
    }
}

extension LocationManager {
    static func isAuthorizationDenied() -> Bool {
        let authorizationStatus = LocationManager.authorizationStatus()
        return authorizationStatus == .denied || authorizationStatus == .restricted
    }
}