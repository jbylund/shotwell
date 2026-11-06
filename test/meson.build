# SPDX-FileCopyrightText: Software Freedom Conservancy Inc.
# SPDX-License-Identifier: LGPL-2.1-or-later
natural_collate_test = executable('natural-collate-test',
                                  ['NaturalCollate-Test.vala', 'NaturalCollate.vala'],
                                  dependencies : gio)

jfif_support_test = executable('jfif-support-test',
                               ['jfif/JfifSupport-Test.vala',
                                'jfif/PhotoFileSniffer.vala',
                                'jfif/PhotoFileAdapter.vala',
                                'jfif/JfifSupport.vala',
                                'jfif/GlycinSupport.vala',
                                'jfif/KeyValueMap.vala',
                                'jfif/Dimensions.vala',
                                'jfif/string.vala',
                                'jfif/file.vala',
                                'jfif/util_core-stub.vala',
                                'jfif/ProgressMonitor-stub.vala',
                                'jfif/PhotoMetadata-stub.vala',
                                'jfif/PhotoFileFormat-jfifstub.vala',
                                'jfif/util_image-stub.vala'],
                               dependencies : [gio, gee, gtk, gexiv2, math, glycin],
                               c_args : ['-DTEST_DATA_DIR="@0@"'.format(meson.current_source_dir())]
                             )

raw_developer_test = executable('raw-developer-test',
                                ['raw-developer/RawDeveloper-Test.vala',
                                 'raw-developer/RawSupport.vala',
                                 'raw-developer/GRaw.vala',
                                 'raw-developer/PhotoFileSniffer.vala',
                                 'raw-developer/PhotoFileAdapter.vala',
                                 'raw-developer/JfifSupport.vala',
                                 'raw-developer/GlycinSupport.vala',
                                 'raw-developer/KeyValueMap.vala',
                                 'raw-developer/Dimensions.vala',
                                 'raw-developer/string.vala',
                                 'raw-developer/file.vala',
                                 'raw-developer/RawDeveloper-stubs.vala',
                                 'jfif/util_core-stub.vala',
                                 'jfif/ProgressMonitor-stub.vala',
                                 'jfif/PhotoFileFormat-jfifstub.vala',
                                 'jfif/util_image-stub.vala'],
                                dependencies : [gio, gee, gtk, libraw, math, glycin],
                                c_args : ['-DTEST_DATA_DIR="@0@"'.format(meson.current_source_dir())]
                              )

regexp_replace_test = executable('regexp-replace-test',
                                 ['RegexpReplace.vala', 'DatabaseTable.vala'],
                                 dependencies: [gee, gio, sqlite])

test('natural-collate', natural_collate_test)
test('jfif-support', jfif_support_test)
test('raw-developer', raw_developer_test)
test('regexp-replace', regexp_replace_test)
