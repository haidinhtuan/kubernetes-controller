package controller

import (
	"os"
	"path/filepath"
	"testing"

	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/envtest"

	migrationv1alpha1 "github.com/haidinhtuan/kubernetes-controller/api/v1alpha1"
)

var cfg *rest.Config
var testEnv *envtest.Environment

func TestMain(m *testing.M) {
	testEnv = &envtest.Environment{
		CRDDirectoryPaths: []string{
			filepath.Join("..", "..", "config", "crd", "bases"),
		},
	}

	var err error
	cfg, err = testEnv.Start()
	if err != nil {
		// envtest binaries might not be installed; unit tests still run
		cfg = nil
		testEnv = nil
	}

	_ = migrationv1alpha1.AddToScheme(scheme.Scheme)

	code := m.Run()

	if testEnv != nil {
		testEnv.Stop()
	}
	os.Exit(code)
}
