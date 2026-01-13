package controller

import (
	"context"
	"fmt"
	"time"

	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	migrationv1alpha1 "github.com/vibe-kanban/kubernetes-controller/api/v1alpha1"
)

// StatefulMigrationReconciler reconciles a StatefulMigration object
type StatefulMigrationReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=migration.vibe.io,resources=statefulmigrations,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=migration.vibe.io,resources=statefulmigrations/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=migration.vibe.io,resources=statefulmigrations/finalizers,verbs=update

// Reconcile is part of the main kubernetes reconciliation loop which aims to
// move the current state of the cluster closer to the desired state.
func (r *StatefulMigrationReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// Fetch the StatefulMigration instance
	migration := &migrationv1alpha1.StatefulMigration{}
	if err := r.Get(ctx, req.NamespacedName, migration); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	logger.Info("Reconciling StatefulMigration", "phase", migration.Status.Phase)

	// State Machine
	switch migration.Status.Phase {
	case "":
		// Initial state, move to Pending
		migration.Status.Phase = migrationv1alpha1.PhasePending
		if err := r.Status().Update(ctx, migration); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{Requeue: true}, nil

	case migrationv1alpha1.PhasePending:
		// Validate and start checkpointing
		return r.handlePending(ctx, migration)

	case migrationv1alpha1.PhaseCheckpointing:
		return r.handleCheckpointing(ctx, migration)

	case migrationv1alpha1.PhaseTransferring:
		return r.handleTransferring(ctx, migration)

	case migrationv1alpha1.PhaseRestoring:
		return r.handleRestoring(ctx, migration)

	case migrationv1alpha1.PhaseReplaying:
		return r.handleReplaying(ctx, migration)

	case migrationv1alpha1.PhaseFinalizing:
		return r.handleFinalizing(ctx, migration)

	case migrationv1alpha1.PhaseCompleted, migrationv1alpha1.PhaseFailed:
		// Terminal states, no action
		return ctrl.Result{}, nil
	}

	return ctrl.Result{}, nil
}

func (r *StatefulMigrationReconciler) handlePending(ctx context.Context, m *migrationv1alpha1.StatefulMigration) (ctrl.Result, error) {
	// TODO: Validate inputs (SourcePod existence, etc.)
	// Transition to Checkpointing
	m.Status.Phase = migrationv1alpha1.PhaseCheckpointing
	if err := r.Status().Update(ctx, m); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{Requeue: true}, nil
}

func (r *StatefulMigrationReconciler) handleCheckpointing(ctx context.Context, m *migrationv1alpha1.StatefulMigration) (ctrl.Result, error) {
	// TODO: 1. Create secondary message queue
	// TODO: 2. Call Kubelet Checkpoint API
	
	// Mock success for now
	m.Status.CheckpointID = fmt.Sprintf("chk-%d", time.Now().Unix())
	m.Status.Phase = migrationv1alpha1.PhaseTransferring
	if err := r.Status().Update(ctx, m); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{Requeue: true}, nil
}

func (r *StatefulMigrationReconciler) handleTransferring(ctx context.Context, m *migrationv1alpha1.StatefulMigration) (ctrl.Result, error) {
	// TODO: Launch Job to build OCI image from checkpoint and push to registry
	
	// Mock success
	m.Status.Phase = migrationv1alpha1.PhaseRestoring
	if err := r.Status().Update(ctx, m); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{Requeue: true}, nil
}

func (r *StatefulMigrationReconciler) handleRestoring(ctx context.Context, m *migrationv1alpha1.StatefulMigration) (ctrl.Result, error) {
	// TODO: Create Pod on Target Node using Checkpoint Image
	
	// Mock success
	m.Status.TargetPod = m.Spec.SourcePod + "-restored" // Example name
	m.Status.Phase = migrationv1alpha1.PhaseReplaying
	if err := r.Status().Update(ctx, m); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{Requeue: true}, nil
}

func (r *StatefulMigrationReconciler) handleReplaying(ctx context.Context, m *migrationv1alpha1.StatefulMigration) (ctrl.Result, error) {
	// TODO: Send START_REPLAY, monitor lag, enforce cutoff
	
	// Mock success
	m.Status.Phase = migrationv1alpha1.PhaseFinalizing
	if err := r.Status().Update(ctx, m); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{Requeue: true}, nil
}

func (r *StatefulMigrationReconciler) handleFinalizing(ctx context.Context, m *migrationv1alpha1.StatefulMigration) (ctrl.Result, error) {
	// TODO: Send END_REPLAY, switch traffic, delete source
	
	m.Status.Phase = migrationv1alpha1.PhaseCompleted
	if err := r.Status().Update(ctx, m); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}

// SetupWithManager sets up the controller with the Manager.
func (r *StatefulMigrationReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&migrationv1alpha1.StatefulMigration{}).
		Complete(r)
}
