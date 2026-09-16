// SPDX-FileCopyrightText: 2020-present Open Networking Foundation <info@opennetworking.org>
//
// SPDX-License-Identifier: Apache-2.0

package compiler

import (
	"github.com/stretchr/testify/assert"
	"testing"
)

func TestLoadMetaData(t *testing.T) {
	path := "../../test/metadata"

	md := &MetaData{LintModel: true, RequireHyphenated: true}
	if err := LoadMetaData(path, "valid", md); err != nil {
		t.Fatal(err)
	}

	err := LoadMetaData(path, "not-existing", md)
	assert.Error(t, err)
	assert.True(t, md.LintModel)
	assert.True(t, md.RequireHyphenated)
}

func TestValidateMetaData(t *testing.T) {
	missingName := &MetaData{Name: "", LintModel: true, RequireHyphenated: true}
	err := ValidateMetaData(missingName)
	assert.Error(t, err)
	assert.Equal(t, "name is mandatory", err.Error())
}

// TestLoadMetaData_GeneratorFlags checks that generatorFlags is read from
// metadata.yaml.
func TestLoadMetaData_GeneratorFlags(t *testing.T) {
	md := &MetaData{LintModel: true, RequireHyphenated: true}
	if err := LoadMetaData("../../test/metadata", "valid", md); err != nil {
		t.Fatal(err)
	}
	assert.Equal(t, []string{"-ignore_unsupported", "-generate_simple_unions"}, md.GeneratorFlags)
}

// TestMetaData_GeneratorFlagsEmpty checks that an unset generatorFlags yields
// no extra arguments. The append in generateGolangBindings is guarded by
// len() > 0, so existing models are unaffected.
func TestMetaData_GeneratorFlagsEmpty(t *testing.T) {
	md := &MetaData{Name: "x", LintModel: true, RequireHyphenated: true}
	assert.Empty(t, md.GeneratorFlags)
}
