//
// Copyright © 2021 DHSC. All rights reserved.
//

import Combine
import Common
import Domain
import Interface
import Localization
import UIKit

extension LinkTestValidationError {
    init(_ linkTestResultError: LinkTestResultError) {
        switch linkTestResultError {
        case .invalidCode:
            self = LinkTestValidationError.testCode(DisplayableError(.link_test_result_enter_code_invalid_error))
        case .noInternet:
            self = LinkTestValidationError.testCode(DisplayableError(.network_error_no_internet_connection))
        case .decodeFailed:
            self = LinkTestValidationError.decodeFailed
        case .unknownError:
            self = LinkTestValidationError.testCode(DisplayableError(.network_error_general))
        }
    }
}

struct HomeFlowViewControllerInteractor: HomeFlowViewController.Interacting {
    
    func getHomeAnimationsViewModel() -> HomeAnimationsViewModel {
        
        let reduceMotionPublisher = NotificationCenter.default.publisher(
            for: UIAccessibility.reduceMotionStatusDidChangeNotification
        )
        .receive(on: RunLoop.main)
        .map { _ in UIAccessibility.isReduceMotionEnabled }
        .prepend(UIAccessibility.isReduceMotionEnabled)
        .eraseToAnyPublisher()
        
        return HomeAnimationsViewModel(
            homeAnimationEnabled: context.homeAnimationsStore.homeAnimationsEnabled.interfaceProperty,
            homeAnimationEnabledAction: { enabled in
                self.context.homeAnimationsStore.save(enabled: enabled)
            }, reduceMotionPublisher: reduceMotionPublisher
        )
    }
    
    func getCurrentLocaleConfiguration() -> InterfaceProperty<LocaleConfiguration> {
        context.currentLocaleConfiguration.interfaceProperty
    }
    
    func storeNewLanguage(_ localeConfiguration: LocaleConfiguration) {
        context.storeNewLanguage(localeConfiguration)
    }
    
    var context: RunningAppContext
    var currentDateProvider: DateProviding
    
    func makeLocalAuthorityOnboardingInteractor() -> LocalAuthorityFlowViewController.Interacting {
        return LocalAuthorityOnboardingInteractor(
            openURL: context.openURL,
            getLocalAuthorities: context.getLocalAuthorities,
            storeLocalAuthority: context.storeLocalAuthorities
        )
    }
    
    func makeDiagnosisViewController() -> UIViewController? {
        WrappingViewController {
            SelfDiagnosisOrderFlowState.makeState(context: context)
                .map { state in
                    switch state {
                    case .selfDiagnosis(let interactor):
                        return SelfDiagnosisFlowViewController(interactor, currentDateProvider: currentDateProvider)
                    case .testOrdering(let interactor):
                        return VirologyTestingFlowViewController(interactor)
                    }
                }
        }
    }
    
    func makeCheckInViewController() -> UIViewController? {
        guard let checkInContext = context.checkInContext else { return nil }
        
        let interactor = CheckInInteractor(
            _openSettings: context.openSettings,
            _process: {
                let (venueName, removeCurrentCheckIn) = try checkInContext.checkInsStore.checkIn(with: $0, currentDate: self.context.currentDateProvider.currentDate)
                return CheckInDetail(venueName: venueName, removeCurrentCheckIn: removeCurrentCheckIn)
            }
        )
        
        let qrCodeScanner = checkInContext.qrCodeScanner
        
        let cameraPermissionStatePublisher = qrCodeScanner.cameraStateController.$authorizationState.map { state -> CameraPermissionState in
            switch state {
            case .notDetermined:
                return .notDetermined
            case .authorized:
                return .authorized
            case .denied, .restricted:
                return .denied
            }
        }.eraseToAnyPublisher()
        
        qrCodeScanner.reset()
        let scanner = QRScanner(
            state: qrCodeScanner.getState().map { state in
                switch state {
                case .starting:
                    return .starting
                case .failed:
                    return .failed
                case .requestingPermission:
                    return .requestingPermission
                case .running:
                    return .running
                case .scanning:
                    return .scanning
                case .processing:
                    return .processing
                case .stopped:
                    return .stopped
                }
            }.eraseToAnyPublisher(),
            startScanning: qrCodeScanner.startScanner,
            stopScanning: qrCodeScanner.stopScanner,
            layoutFinished: qrCodeScanner.changeOrientation
        )
        
        return CheckInFlowViewController(
            cameraPermissionState: cameraPermissionStatePublisher,
            scanner: scanner,
            interactor: interactor,
            currentDateProvider: currentDateProvider,
            goHomeCompletion: context.appReviewPresenter.presentReview
        )
    }
    
    func makeTestingInformationViewController(flowController: UINavigationController?, showWarnAndBookATestFlow: InterfaceProperty<Bool>) -> UIViewController? {
        if showWarnAndBookATestFlow.wrappedValue {
            return warnAndBookATestViewController(flowController: flowController)
        } else {
            return bookATestViewController()
        }
    }
    
    private func bookATestViewController() -> UIViewController {
        WrappingViewController {
            BookATestFlowState.makeState(context: context)
                .map { state in
                    switch state {
                    case .bookATest(let interactor):
                        return BaseNavigationController(rootViewController: BookATestInfoViewController(interactor: interactor, shouldHaveCancelButton: true))
                    case .testOrdering(let interactor):
                        return VirologyTestingFlowViewController(interactor)
                    }
                }
        }
    }
    
    private func warnAndBookATestViewController(flowController: UINavigationController?) -> UIViewController {
        let navigationVC = BaseNavigationController()
        let checkSymptomsInteractor = TestCheckSymptomsInteractor(
            didTapYes: {
                Metrics.signpost(.selectedHasSymptomsM2Journey)
                let vc = WrappingViewController {
                    SelfDiagnosisOrderFlowState.makeState(
                        context: self.context,
                        acknowledge: {
                            flowController?.popViewController(animated: false)
                            navigationVC.presentedViewController?.dismiss(animated: false, completion: nil)
                            navigationVC.dismiss(animated: false, completion: nil)
                        }
                    )
                    .map { state in
                        switch state {
                        case .selfDiagnosis(let interactor):
                            let selfDiagnosisFlowVC = SelfDiagnosisFlowViewController(interactor, currentDateProvider: self.context.currentDateProvider)
                            selfDiagnosisFlowVC.finishFlow = {
                                flowController?.popViewController(animated: false)
                                navigationVC.presentedViewController?.dismiss(animated: false, completion: nil)
                                navigationVC.dismiss(animated: false, completion: nil)
                            }
                            return selfDiagnosisFlowVC
                        case .testOrdering(let interactor):
                            return VirologyTestingFlowViewController(interactor)
                        }
                    }
                }
                vc.modalPresentationStyle = .overFullScreen
                navigationVC.present(vc, animated: true, completion: nil)
            },
            didTapNo: {
                Metrics.signpost(.selectedHasNoSymptomsM2Journey)
                let interactor = BookARapidTestInfoInteractor(openURL: context.openURL)
                let vc = BookARapidTestInfoViewController(interactor: interactor)
                interactor.dismiss = {
                    flowController?.popViewController(animated: false)
                    navigationVC.dismiss(animated: true, completion: nil)
                }
                navigationVC.pushViewController(vc, animated: true)
            }
        )
        let checkSymptomsVC = TestCheckSymptomsViewController.viewController(
            for: .warnAndBookATest,
            interactor: checkSymptomsInteractor,
            shouldHaveCancelButton: true
        )
        checkSymptomsVC.didCancel = {}
        navigationVC.viewControllers = [checkSymptomsVC]
        return navigationVC
    }
    
    func makeFinancialSupportViewController() -> UIViewController? {
        switch context.isolationPaymentState.currentValue {
        case .disabled: return nil
        case .enabled(let apply):
            return IsolationPaymentFlowViewController(openURL: context.openURL, didTapCheckEligibility: apply, recordLaunchedIsolationPaymentsApplication: { Metrics.signpost(.launchedIsolationPaymentsApplication) })
        }
    }
    
    func makeLinkTestResultViewController() -> UIViewController? {
        
        let baseNavigationController = BaseNavigationController()
        
        let interactor = LinkTestResultInteractor(
            dailyContactTestingEarlyTerminationSupport: context.dailyContactTestingEarlyTerminationSupport(),
            showNextScreen: { terminate in
                if let dailyConfirmationVC = makeDailyConfirmationViewController(
                    parentVC: baseNavigationController,
                    with: terminate
                ) {
                    baseNavigationController.pushViewController(dailyConfirmationVC, animated: true)
                }
            },
            openURL: context.openURL,
            onCancel: {
                baseNavigationController.dismiss(animated: true, completion: nil)
            },
            onSubmit: { testCode in
                self.context.virologyTestingManager.linkExternalTestResult(with: testCode)
                    .mapError(LinkTestValidationError.init)
                    .eraseToAnyPublisher()
            }
        )
        baseNavigationController.pushViewController(LinkTestResultViewController(interactor: interactor), animated: false)
        
        return baseNavigationController
    }
    
    func makeDailyConfirmationViewController(parentVC: UIViewController, with terminate: @escaping () -> Void) -> UIViewController? {
        
        let interactor = DailyContactTestingConfirmationInteractor(
            action: {
                let alertController = makeDCTConfirmationAlert(with: terminate)
                parentVC.present(alertController, animated: true)
            }
            
        )
        
        return DailyContactTestingConfirmationViewController(interactor: interactor)
    }
    
    private func makeDCTConfirmationAlert(with action: @escaping () -> Void) -> UIAlertController {
        let alertController = UIAlertController(
            title: localize(.daily_contact_testing_confirmation_screen_alert_title),
            message: localize(.daily_contact_testing_confirmation_screen_alert_body_description),
            preferredStyle: .alert
        )
        
        let confirmAction = UIAlertAction(title: localize(.daily_contact_testing_confirmation_screen_alert_confirm_button_title), style: .default) { _ in action() }
        
        alertController.addAction(UIAlertAction(title: localize(.cancel), style: .default))
        alertController.addAction(confirmAction)
        alertController.preferredAction = confirmAction
        
        return alertController
    }
    
    public func makeContactTracingHubViewController(flowController: UINavigationController?, exposureNotificationsEnabled: InterfaceProperty<Bool>, exposureNotificationsToggleAction: @escaping (Bool) -> Void, userNotificationsEnabled: InterfaceProperty<Bool>) -> UIViewController {
        
        struct ContactTracingHubViewControllerInteractor: ContactTracingHubViewController.Interacting {
            let flowInteractor: HomeFlowViewControllerInteracting
            weak var flowController: UINavigationController?
            
            func scheduleReminderNotification(reminderIn: ExposureNotificationReminderIn) {
                flowInteractor.scheduleReminderNotification(reminderIn: reminderIn)
            }
            
            func didTapAdviceWhenDoNotPauseCTButton() {
                let viewController = ContactTracingAdviceViewController()
                flowController?.pushViewController(viewController, animated: true)
            }
        }
        
        let contactTracingInteractor = ContactTracingHubViewControllerInteractor(flowInteractor: self, flowController: flowController)
        let viewController = ContactTracingHubViewController(
            contactTracingInteractor,
            exposureNotificationsEnabled: exposureNotificationsEnabled,
            exposureNotificationsToggleAction: exposureNotificationsToggleAction,
            userNotificationsEnabled: userNotificationsEnabled
        )
        return viewController
    }
    
    func makeLocalInfoScreenViewController(
        viewModel: LocalInformationViewController.ViewModel,
        interactor: LocalInformationViewController.Interacting
    ) -> UIViewController {
        let viewController = LocalInformationViewController(viewModel: viewModel, interactor: interactor)
        return viewController
    }
    
    func removeDeliveredLocalInfoNotifications() {
        context.userNotificationManaging.removeAllDelivered(for: UserNotificationType.localMessage(title: "", body: ""))
    }
    
    func makeTestingHubViewController(
        flowController: UINavigationController?,
        showOrderTestButton: InterfaceProperty<Bool>,
        showFindOutAboutTestingButton: InterfaceProperty<Bool>,
        showWarnAndBookATestFlow: InterfaceProperty<Bool>
    ) -> UIViewController {
        
        final class TestingHubViewControllerInteractor: TestingHubViewController.Interacting {
            
            private weak var flowController: UINavigationController?
            private let flowInteractor: HomeFlowViewControllerInteracting
            private var didEnterBackgroundCancellable: Cancellable?
            private let showWarnAndBookATestFlow: InterfaceProperty<Bool>
            
            init(flowController: UINavigationController?, flowInteractor: HomeFlowViewControllerInteracting, showWarnAndBookATestFlow: InterfaceProperty<Bool>) {
                self.flowController = flowController
                self.flowInteractor = flowInteractor
                self.showWarnAndBookATestFlow = showWarnAndBookATestFlow
            }
            
            func didTapBookFreeTestButton() {
                guard let viewController = flowInteractor.makeTestingInformationViewController(flowController: flowController, showWarnAndBookATestFlow: showWarnAndBookATestFlow) else { return }
                viewController.modalPresentationStyle = .overFullScreen
                flowController?.present(viewController, animated: true)
            }
            
            func didTapFindOutAboutTestingButton() {
                didEnterBackgroundCancellable = NotificationCenter.default
                    .publisher(for: UIApplication.didEnterBackgroundNotification)
                    .first()
                    .sink { [weak flowController] _ in
                        flowController?.popViewController(animated: false)
                    }
                
                flowInteractor.openAdvice()
            }
            
            func didTapEnterTestResultButton() {
                guard let viewController = flowInteractor.makeLinkTestResultViewController() else { return }
                flowController?.present(viewController, animated: true)
            }
        }
        
        let interactor = TestingHubViewControllerInteractor(flowController: flowController, flowInteractor: self, showWarnAndBookATestFlow: showWarnAndBookATestFlow)
        
        return TestingHubViewController(
            interactor: interactor,
            showOrderTestButton: showOrderTestButton,
            showFindOutAboutTestingButton: showFindOutAboutTestingButton
        )
    }
    
    func recordDidTapLocalInfoBannerMetric() {
        Metrics.signpost(.didAccessLocalInfoScreenViaBanner)
    }
    
    func setExposureNotifcationEnabled(_ enabled: Bool) -> AnyPublisher<Void, Never> {
        context.exposureNotificationStateController.setEnabled(enabled)
    }
    
    public func scheduleReminderNotification(reminderIn: ExposureNotificationReminderIn) {
        guard let date = context.exposureNotificationReminder.scheduleUserNotification(in: reminderIn.rawValue) else {
            return
        }
        context.exposureNotificationReminder.scheduleSecondUserNotification(afterFirstReminderDate: date)
    }
    
    var shouldShowCheckIn: Bool {
        context.checkInContext != nil
    }
    
    func getMyAreaViewModel() -> MyAreaTableViewController.ViewModel {
        MyAreaTableViewController.ViewModel(
            postcode: context.postcodeInfo.map { $0?.postcode.value }.interfaceProperty,
            localAuthority: context.postcodeInfo.map { $0?.localAuthority?.name }.interfaceProperty
        )
    }
    
    func getMyDataViewModel() -> MyDataViewController.ViewModel {
        
        // map from the Domain level ConfirmationStatus to the Interface level ConfirmationStatus
        let testResultDetails: MyDataViewController.ViewModel.TestResultDetails? = context.testInfo.currentValue.flatMap {
            guard let interfaceTestResult = Interface.TestResult(domainTestResult: $0.result) else { return nil }
            let completionStatus: MyDataViewController.ViewModel.TestResultDetails.CompletionStatus = { testInfo in
                switch testInfo.completionStatus {
                case .pending:
                    return MyDataViewController.ViewModel.TestResultDetails.CompletionStatus.pending
                case .notRequired:
                    return MyDataViewController.ViewModel.TestResultDetails.CompletionStatus.notRequired
                case .completed(let completedOnDay):
                    return MyDataViewController.ViewModel.TestResultDetails.CompletionStatus.completed(onDay: completedOnDay)
                }
            }($0)
            
            return MyDataViewController.ViewModel.TestResultDetails(
                result: interfaceTestResult,
                acknowledgementDate: $0.receivedOnDay.startDate(in: .current),
                testEndDate: $0.testEndDay?.startDate(in: .current),
                testKitType: $0.testKitType.map(Interface.TestKitType.init(domainTestKitType:)),
                completionStatus: completionStatus
            )
        }
        
        let symptomsOnsetDate = context.symptomsOnsetAndExposureDetailsProvider.provideSymptomsOnsetDate()
        let exposureDetails = context.symptomsOnsetAndExposureDetailsProvider.provideExposureDetails()
        
        // TODO: We may want to pass this through as an interface property or similar rather than computing its instantaneous value here.
        let selfIsolationEndDate = { () -> Date? in
            switch context.isolationState.currentValue {
            case .isolate(let isolation):
                return isolation.endDate
            case .noNeedToIsolate:
                return nil
            }
        }()
        // TODO: We may want to pass this through as an interface property or similar rather than computing its instantaneous value here.
        let dailyTestingOptInDate = { () -> Date? in
            switch context.isolationState.currentValue {
            case .isolate:
                return nil
            case .noNeedToIsolate(let date):
                return date
            }
        }()
        // TODO: We may want to pass this through as an interface property or similar rather than computing its instantaneous value here.
        let venueOfRiskDate = context.checkInContext?.recentlyVisitedSevereRiskyVenue.currentValue
        
        return .init(
            testResultDetails: testResultDetails,
            symptomsOnsetDate: symptomsOnsetDate,
            exposureNotificationDetails: exposureDetails.map { details in
                MyDataViewController.ViewModel.ExposureNotificationDetails(
                    encounterDate: details.encounterDate,
                    notificationDate: details.notificationDate
                )
            },
            selfIsolationEndDate: selfIsolationEndDate,
            dailyTestingOptInDate: dailyTestingOptInDate,
            venueOfRiskDate: venueOfRiskDate?.startDate(in: .current)
        )
    }
    
    func loadVenueHistory() -> [VenueHistory] {
        context.checkInContext?.checkInsStore.load()?
            .map { checkIn -> VenueHistory in
                VenueHistory(
                    id: VenueHistory.ID(value: checkIn.id),
                    venueId: checkIn.venueId,
                    organisation: checkIn.venueName,
                    postcode: checkIn.venuePostcode,
                    checkedIn: checkIn.checkedIn.date,
                    checkedOut: checkIn.checkedOut.date
                )
            } ?? []
    }
    
    func getVenueHistoryViewModel() -> VenueHistoryViewController.ViewModel {
        return VenueHistoryViewController.ViewModel(venueHistories: loadVenueHistory())
    }
    
    func openIsolationAdvice() {
        context.openURL(ExternalLink.isolationAdvice.url)
    }
    
    func openAdvice() {
        context.openURL(ExternalLink.generalAdvice.url)
    }
    
    func openDailyContactTestingInformation() {
        context.openURL(ExternalLink.dailyContactTestingInformation.url)
    }
    
    func deleteAppData() {
        context.deleteAllData()
    }
    
    func updateVenueHistories(deleting venueHistory: VenueHistory) -> [VenueHistory] {
        let checkInId = venueHistory.id.value
        context.deleteCheckIn(checkInId)
        return loadVenueHistory()
    }
    
    func openTearmsOfUseLink() {
        context.openURL(ExternalLink.ourPolicies.url)
    }
    
    func openPrivacyLink() {
        context.openURL(ExternalLink.privacy.url)
    }
    
    func openFAQ() {
        context.openURL(ExternalLink.faq.url)
    }
    
    func openAccessibilityStatementLink() {
        context.openURL(ExternalLink.accessibilityStatement.url)
    }
    
    func openHowThisAppWorksLink() {
        context.openURL(ExternalLink.howThisAppWorks.url)
    }
    
    func openWebsiteLinkfromRisklevelInfoScreen(url: URL) {
        context.openURL(url)
    }
    
    func openWebsiteLinkfromLocalInfoScreen(url: URL) {
        context.openURL(url)
    }
    
    func openProvideFeedbackLink() {
        context.openURL(ExternalLink.provideFeedback.url)
    }
    
    func openDownloadNHSAppLink() {
        context.openURL(ExternalLink.downloadNHSApp.url)
    }
}

private struct TestCheckSymptomsInteractor: TestCheckSymptomsViewController.Interacting {
    var didTapYes: () -> Void
    var didTapNo: () -> Void
}

private class BookARapidTestInfoInteractor: BookARapidTestInfoViewController.Interacting {
    public let openURL: (URL) -> Void
    var dismiss: (() -> Void)?
    
    init(openURL: @escaping (URL) -> Void) {
        self.openURL = openURL
    }
    
    func didTapAlreadyHaveATest() {
        Metrics.signpost(.selectedHasLFDTestM2Journey)
        dismiss?()
    }
    
    func didTapBookATest() {
        Metrics.signpost(.selectedLFDTestOrderingM2Journey)
        openURL(ExternalLink.getTested.url)
        dismiss?()
    }
    
}
