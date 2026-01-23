package main

import (
	"testing"
)

func TestParseWeightedList(t *testing.T) {
	// Good inputs.
	for _, test := range []struct {
		input           string
		expectedWeights []uint32
		expectedLabels  []string
	}{
		{"a", []uint32{1}, []string{"a"}},
		{"apple", []uint32{1}, []string{"apple"}},
		{"1*apple", []uint32{1}, []string{"apple"}},
		{"apple,2*carrot,1*apple", []uint32{1, 2, 1}, []string{"apple", "carrot", "apple"}},
		{"\\a", []uint32{1}, []string{"a"}},
		{"\\*", []uint32{1}, []string{"*"}},
		{"\\,", []uint32{1}, []string{","}},
		{"3\\*apple\\,car\\rot,100*orange", []uint32{1, 100}, []string{"3*apple,carrot", "orange"}},
	} {
		weights, labels, err := parseWeightedList(test.input)
		if err != nil {
			t.Errorf("%+q resulted in error: %v", test.input, err)
			continue
		}
		i := 0
		for ; i < len(weights) && i < len(labels) && i < len(test.expectedWeights) && i < len(test.expectedLabels); i++ {
			if weights[i] != test.expectedWeights[i] {
				break
			}
			if labels[i] != test.expectedLabels[i] {
				break
			}
		}
		if i < len(test.expectedWeights) || i < len(test.expectedLabels) {
			t.Errorf("%+q: expected %v, %v, got %v, %v", test.input,
				test.expectedWeights, test.expectedLabels, weights, labels)
			continue
		}
	}

	// Bad inputs.
	for _, input := range []string{
		"",
		"apple*1",
		",",
		",apple",
		"apple,",
		"apple,,carrot",
		"*",
		"**",
		"5*apple*5",
		"-5*apple",
		"5.5*apple",
	} {
		_, _, err := parseWeightedList(input)
		if err == nil {
			t.Errorf("%+q resulted in no error", input)
			continue
		}
	}
}

func TestSampleWeighted(t *testing.T) {
	// Total weight of zero should result in a panic.
	for _, weights := range [][]uint32{
		{},
		{0},
		{0, 0, 0, 0, 0},
	} {
		func() {
			defer func() {
				r := recover()
				if r == nil {
					t.Errorf("%v: expected panic", weights)
				}
			}()
			sampleWeighted(weights)
		}()
	}

	// If there is only one nonzero weight, it should be always selected.
	for _, test := range []struct {
		weights []uint32
		index   int
	}{
		{[]uint32{1}, 0},
		{[]uint32{1, 0, 0, 0, 0}, 0},
		{[]uint32{0, 0, 0, 0, 1}, 4},
		{[]uint32{0, 0, 0xffffffff, 0, 1}, 2},
	} {
		for i := 0; i < 100; i++ {
			index := sampleWeighted(test.weights)
			if index != test.index {
				t.Errorf("%v: expected %d, got %d", test.weights, test.index, index)
			}
		}
	}
}
