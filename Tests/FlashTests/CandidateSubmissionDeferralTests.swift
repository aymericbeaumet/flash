import XCTest

@testable import flash

final class CandidateSubmissionDeferralTests: XCTestCase {
  func testRapidCalculatorSubmitWaitsForExactEvaluationThenReplays() {
    let action = CandidateSubmissionDeferral.Action(
      submit: false,
      allowFinisher: true,
      submitFinalDestinations: false)
    var deferral = CandidateSubmissionDeferral()
    deferral.deferAction(
      action,
      sessionGeneration: 4,
      query: "1+1",
      evaluationGeneration: 9)

    XCTAssertEqual(
      deferral.resolve(
        sessionGeneration: 4,
        query: "1+1",
        currentEvaluationGeneration: 9,
        initialSnapshotPending: false,
        evaluationInFlightGeneration: 9),
      .waiting)
    XCTAssertEqual(
      deferral.resolve(
        sessionGeneration: 4,
        query: "1+1",
        currentEvaluationGeneration: 9,
        initialSnapshotPending: false,
        evaluationInFlightGeneration: nil),
      .replay(action))
    XCTAssertEqual(
      deferral.resolve(
        sessionGeneration: 4,
        query: "1+1",
        currentEvaluationGeneration: 9,
        initialSnapshotPending: false,
        evaluationInFlightGeneration: nil),
      .none)
  }

  func testInitialSnapshotSubmitBindsToEvaluatorGenerationBeforeReplay() {
    let action = CandidateSubmissionDeferral.Action(
      submit: true,
      allowFinisher: true,
      submitFinalDestinations: false)
    var deferral = CandidateSubmissionDeferral()
    deferral.deferAction(
      action,
      sessionGeneration: 7,
      query: "1+1",
      evaluationGeneration: nil)

    XCTAssertEqual(
      deferral.resolve(
        sessionGeneration: 7,
        query: "1+1",
        currentEvaluationGeneration: 2,
        initialSnapshotPending: true,
        evaluationInFlightGeneration: nil),
      .waiting)
    XCTAssertEqual(
      deferral.resolve(
        sessionGeneration: 7,
        query: "1+1",
        currentEvaluationGeneration: 3,
        initialSnapshotPending: false,
        evaluationInFlightGeneration: 3),
      .waiting)
    XCTAssertEqual(
      deferral.resolve(
        sessionGeneration: 7,
        query: "1+1",
        currentEvaluationGeneration: 3,
        initialSnapshotPending: false,
        evaluationInFlightGeneration: nil),
      .replay(action))
  }

  func testDeferredSubmitIsDiscardedAfterQueryOrGenerationChanges() {
    let action = CandidateSubmissionDeferral.Action(
      submit: false,
      allowFinisher: false,
      submitFinalDestinations: true)
    var queryChanged = CandidateSubmissionDeferral()
    queryChanged.deferAction(
      action,
      sessionGeneration: 2,
      query: "1+1",
      evaluationGeneration: 5)
    XCTAssertEqual(
      queryChanged.resolve(
        sessionGeneration: 2,
        query: "1+2",
        currentEvaluationGeneration: 6,
        initialSnapshotPending: false,
        evaluationInFlightGeneration: 6),
      .discarded)

    var returnedToSameText = CandidateSubmissionDeferral()
    returnedToSameText.deferAction(
      action,
      sessionGeneration: 2,
      query: "1+1",
      evaluationGeneration: 5)
    XCTAssertEqual(
      returnedToSameText.resolve(
        sessionGeneration: 2,
        query: "1+1",
        currentEvaluationGeneration: 7,
        initialSnapshotPending: false,
        evaluationInFlightGeneration: 7),
      .discarded)
  }

  func testCancelDropsDeferredSubmit() {
    var deferral = CandidateSubmissionDeferral()
    deferral.deferAction(
      CandidateSubmissionDeferral.Action(
        submit: true,
        allowFinisher: true,
        submitFinalDestinations: false),
      sessionGeneration: 1,
      query: "1+1",
      evaluationGeneration: 2)
    deferral.cancel()

    XCTAssertEqual(
      deferral.resolve(
        sessionGeneration: 1,
        query: "1+1",
        currentEvaluationGeneration: 2,
        initialSnapshotPending: false,
        evaluationInFlightGeneration: nil),
      .none)
  }
}
