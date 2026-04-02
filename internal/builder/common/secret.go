// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package common

import (
	"fmt"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	slinkyv1beta1 "github.com/SlinkyProject/slurm-operator/api/v1beta1"
	"github.com/SlinkyProject/slurm-operator/internal/builder/metadata"
)

type SecretOpts struct {
	Key        types.NamespacedName
	Metadata   slinkyv1beta1.Metadata
	Data       map[string][]byte
	StringData map[string]string
	Immutable  bool
}

func (b *CommonBuilder) BuildSecret(opts SecretOpts, owner metav1.Object) (*corev1.Secret, error) {
	objectMeta := metadata.NewBuilder(opts.Key).
		WithMetadata(opts.Metadata).
		Build()

	out := &corev1.Secret{
		ObjectMeta: objectMeta,
		Data:       opts.Data,
		StringData: opts.StringData,
		Immutable:  ptr.To(opts.Immutable),
	}

	if owner == nil {
		return nil, fmt.Errorf("failed to specify an owner")
	}

	if owner.GetNamespace() == out.GetNamespace() {
		if err := controllerutil.SetControllerReference(owner, out, b.client.Scheme()); err != nil {
			return nil, fmt.Errorf("failed to set owner controller: %w", err)
		}
	}

	return out, nil
}

// SecretKeyBytes returns s.Data[key] when present. Kubernetes API responses populate
// Secret data in Data, not StringData (StringData is write-oriented); using only
// StringData for checksums breaks rolling updates when sssd.conf changes.
func SecretKeyBytes(s *corev1.Secret, key string) []byte {
	if s == nil || key == "" {
		return nil
	}
	if b, ok := s.Data[key]; ok {
		return b
	}
	return []byte(s.StringData[key])
}
