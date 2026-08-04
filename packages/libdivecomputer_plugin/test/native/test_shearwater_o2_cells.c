// Regression test for issue #855: per-cell O2 readings are dropped for
// Shearwater Petrel Native Format (PNF) logs.
//
// shearwater_predator_parser.c disables every O2 sensor when all of them still
// carry the calibration value 2100, on the assumption that the value is a
// factory default and therefore that the cells were never calibrated. On PNF
// logs that assumption is wrong: the same record carries an explicit per-cell
// "calibrated" flag, and the Petrel 3 sets it for all three cells while writing
// 2100 for each of them.
//
// The fixture is the reporter's own Petrel 3 log from issue #810 (the raw
// dive_details/log_data blob out of a Shearwater Cloud database, decompressed).
// It carries three cells per sample, and 2100 is the factor the computer itself
// uses: its display shows ppO2 1.3 where the cells read 62/65/62 mV, and
// median(62) * 0.021 = 1.302.
//
// Without the fix, sample_count is unchanged but every o2_sensor[] entry is NAN.

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libdc_wrapper.h"

static unsigned int load_fixture(const char *path, unsigned char **out) {
    *out = NULL;
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len <= 0) { fclose(f); return 0; }
    unsigned char *buf = (unsigned char *)malloc((size_t)len);
    if (!buf) { fclose(f); return 0; }
    size_t read = fread(buf, 1, (size_t)len, f);
    fclose(f);
    if (read != (size_t)len) { free(buf); return 0; }
    *out = buf;
    return (unsigned int)read;
}

// Every CCR sample in this log carries three cells, and each of them must land
// within a hair of the aggregate ppO2 the computer voted from them. The
// tolerance covers the spread between cells (the vote is their median), not
// measurement error: cell 2 reads a few percent above cells 1 and 3 throughout.
static void test_per_cell_ppo2_is_reported(void) {
    unsigned char *data = NULL;
    unsigned int size = load_fixture("fixtures/petrel3_ccr_o2_cells.bin", &data);
    assert(size == 22400);

    libdc_parsed_dive_t dive;
    char err[256] = {0};
    int rc = libdc_parse_raw_dive("Shearwater", "Petrel 3", 0, data, size, &dive,
                                  err, sizeof(err));
    assert(rc == 0);
    assert(dive.sample_count > 0);

    unsigned int with_cells = 0;
    for (unsigned int i = 0; i < dive.sample_count; ++i) {
        const libdc_sample_t *s = &dive.samples[i];
        if (isnan(s->o2_sensor[0])) continue;
        with_cells++;

        // Three cells present, the rest absent.
        assert(!isnan(s->o2_sensor[1]));
        assert(!isnan(s->o2_sensor[2]));
        assert(isnan(s->o2_sensor[3]));

        // Plausible loop values, and consistent with the computer's own vote.
        for (unsigned int c = 0; c < 3; ++c) {
            assert(s->o2_sensor[c] > 0.4 && s->o2_sensor[c] < 2.0);
            if (!isnan(s->ppo2)) {
                assert(fabs(s->o2_sensor[c] - s->ppo2) < 0.15);
            }
        }
    }

    // The dive runs closed circuit throughout, so every sample carries cells.
    assert(with_cells == dive.sample_count);
    printf("PASS: test_per_cell_ppo2_is_reported (%u samples with 3 cells)\n",
           with_cells);

    libdc_parsed_dive_free(&dive);
    free(data);
}

// The aggregate must keep coming through untouched: it is what the profile
// plots today, and it is the value Shearwater Cloud's own UDDF export of this
// dive contains (0.85, 0.90, 0.79, 0.86, ... for the first samples).
static void test_aggregate_ppo2_still_reported(void) {
    unsigned char *data = NULL;
    unsigned int size = load_fixture("fixtures/petrel3_ccr_o2_cells.bin", &data);
    assert(size == 22400);

    libdc_parsed_dive_t dive;
    char err[256] = {0};
    int rc = libdc_parse_raw_dive("Shearwater", "Petrel 3", 0, data, size, &dive,
                                  err, sizeof(err));
    assert(rc == 0);
    assert(dive.sample_count > 0);

    assert(!isnan(dive.samples[0].ppo2));
    assert(fabs(dive.samples[0].ppo2 - 0.85) < 0.005);

    libdc_parsed_dive_free(&dive);
    free(data);
}

int main(void) {
    test_per_cell_ppo2_is_reported();
    test_aggregate_ppo2_still_reported();
    printf("All Shearwater O2 cell tests passed\n");
    return 0;
}
