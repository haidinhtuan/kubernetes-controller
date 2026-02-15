package v1alpha1

import (
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestMigrationStrategyField(t *testing.T) {
	sm := &StatefulMigration{
		Spec: StatefulMigrationSpec{
			MigrationStrategy: "ShadowPod",
		},
	}
	if sm.Spec.MigrationStrategy != "ShadowPod" {
		t.Errorf("expected MigrationStrategy to be 'ShadowPod', got %q", sm.Spec.MigrationStrategy)
	}

	sm.Spec.MigrationStrategy = "Sequential"
	if sm.Spec.MigrationStrategy != "Sequential" {
		t.Errorf("expected MigrationStrategy to be 'Sequential', got %q", sm.Spec.MigrationStrategy)
	}

	// Empty string should be the zero value (auto-detect)
	sm.Spec.MigrationStrategy = ""
	if sm.Spec.MigrationStrategy != "" {
		t.Errorf("expected MigrationStrategy to be empty, got %q", sm.Spec.MigrationStrategy)
	}
}

func TestPhaseTimingsMap(t *testing.T) {
	sm := &StatefulMigration{
		Status: StatefulMigrationStatus{
			PhaseTimings: map[string]string{
				"Checkpointing": "12s",
				"Transferring":  "45s",
				"Restoring":     "8s",
			},
		},
	}

	if len(sm.Status.PhaseTimings) != 3 {
		t.Fatalf("expected 3 phase timings, got %d", len(sm.Status.PhaseTimings))
	}

	expected := map[string]string{
		"Checkpointing": "12s",
		"Transferring":  "45s",
		"Restoring":     "8s",
	}
	for k, v := range expected {
		if sm.Status.PhaseTimings[k] != v {
			t.Errorf("expected PhaseTimings[%q] = %q, got %q", k, v, sm.Status.PhaseTimings[k])
		}
	}
}

func TestStartTimePointer(t *testing.T) {
	// Nil StartTime
	sm := &StatefulMigration{
		Status: StatefulMigrationStatus{},
	}
	if sm.Status.StartTime != nil {
		t.Error("expected StartTime to be nil for new status")
	}

	// Set StartTime
	now := metav1.NewTime(time.Date(2025, 1, 15, 10, 30, 0, 0, time.UTC))
	sm.Status.StartTime = &now
	if sm.Status.StartTime == nil {
		t.Fatal("expected StartTime to be set")
	}
	if !sm.Status.StartTime.Equal(&now) {
		t.Errorf("expected StartTime to match, got %v", sm.Status.StartTime)
	}
}

func TestExchangeNameAndRoutingKeyFields(t *testing.T) {
	mqConfig := MessageQueueConfig{
		QueueName:    "orders-queue",
		BrokerURL:    "amqp://localhost:5672",
		ExchangeName: "orders-exchange",
		RoutingKey:   "orders.new",
	}

	if mqConfig.ExchangeName != "orders-exchange" {
		t.Errorf("expected ExchangeName 'orders-exchange', got %q", mqConfig.ExchangeName)
	}
	if mqConfig.RoutingKey != "orders.new" {
		t.Errorf("expected RoutingKey 'orders.new', got %q", mqConfig.RoutingKey)
	}

	// Verify within a full StatefulMigration
	sm := &StatefulMigration{
		Spec: StatefulMigrationSpec{
			MessageQueueConfig: mqConfig,
		},
	}
	if sm.Spec.MessageQueueConfig.ExchangeName != "orders-exchange" {
		t.Errorf("expected nested ExchangeName 'orders-exchange', got %q", sm.Spec.MessageQueueConfig.ExchangeName)
	}
	if sm.Spec.MessageQueueConfig.RoutingKey != "orders.new" {
		t.Errorf("expected nested RoutingKey 'orders.new', got %q", sm.Spec.MessageQueueConfig.RoutingKey)
	}
}

func TestDeepCopyPhaseTimingsIndependence(t *testing.T) {
	original := &StatefulMigrationStatus{
		Phase: PhasePending,
		PhaseTimings: map[string]string{
			"Checkpointing": "10s",
			"Transferring":  "30s",
		},
	}

	copied := original.DeepCopy()

	// Verify the copy has the same values
	if len(copied.PhaseTimings) != 2 {
		t.Fatalf("expected 2 phase timings in copy, got %d", len(copied.PhaseTimings))
	}
	if copied.PhaseTimings["Checkpointing"] != "10s" {
		t.Errorf("expected copied Checkpointing = '10s', got %q", copied.PhaseTimings["Checkpointing"])
	}

	// Mutate the copy and verify original is unchanged
	copied.PhaseTimings["Checkpointing"] = "99s"
	copied.PhaseTimings["NewPhase"] = "5s"

	if original.PhaseTimings["Checkpointing"] != "10s" {
		t.Errorf("original Checkpointing was mutated: got %q, want '10s'", original.PhaseTimings["Checkpointing"])
	}
	if _, exists := original.PhaseTimings["NewPhase"]; exists {
		t.Error("original PhaseTimings should not contain 'NewPhase' after mutating the copy")
	}
}

func TestDeepCopyStartTimeIndependence(t *testing.T) {
	now := metav1.NewTime(time.Date(2025, 1, 15, 10, 30, 0, 0, time.UTC))
	original := &StatefulMigrationStatus{
		StartTime: &now,
	}

	copied := original.DeepCopy()

	if copied.StartTime == nil {
		t.Fatal("expected StartTime in copy to be non-nil")
	}
	if !copied.StartTime.Equal(original.StartTime) {
		t.Error("copied StartTime should equal original")
	}

	// Ensure they don't share the same pointer
	if original.StartTime == copied.StartTime {
		t.Error("copied StartTime should not share the same pointer as original")
	}
}

func TestDeepCopyNilPhaseTimings(t *testing.T) {
	original := &StatefulMigrationStatus{
		Phase:        PhasePending,
		PhaseTimings: nil,
	}

	copied := original.DeepCopy()

	if copied.PhaseTimings != nil {
		t.Error("expected nil PhaseTimings in copy when original is nil")
	}
}

func TestDeepCopyNilStartTime(t *testing.T) {
	original := &StatefulMigrationStatus{
		Phase:     PhasePending,
		StartTime: nil,
	}

	copied := original.DeepCopy()

	if copied.StartTime != nil {
		t.Error("expected nil StartTime in copy when original is nil")
	}
}
