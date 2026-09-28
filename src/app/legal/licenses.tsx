import { useMemo, useState } from 'react';
import { FlatList, Pressable, StyleSheet, TextInput, View } from 'react-native';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { MaxContentWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { openLegalUrl } from '@/lib/legal/config';

type LicensePackage = {
  name: string;
  version: string;
  license: string;
  repository: string | null;
  textId: number | null;
};

type LicenseData = {
  generatedAt: string;
  packages: LicensePackage[];
  texts: string[];
};

// Settings → Open-source licenses. The list comes from
// scripts/generate-licenses.js (npm run licenses).
export default function LicensesScreen() {
  const theme = useTheme();
  // Loaded when the screen opens rather than at app start: it's ~500 KB.
  const data = useMemo<LicenseData>(() => require('@/lib/legal/licenses.json'), []);
  const [query, setQuery] = useState('');
  const [expanded, setExpanded] = useState<string | null>(null);

  const packages = useMemo(() => {
    const q = query.trim().toLowerCase();
    return q ? data.packages.filter((p) => p.name.toLowerCase().includes(q)) : data.packages;
  }, [data, query]);

  return (
    <ThemedView style={styles.container}>
      <FlatList
        data={packages}
        keyExtractor={(item) => `${item.name}@${item.version}`}
        contentContainerStyle={styles.content}
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="on-drag"
        ListHeaderComponent={
          <View style={styles.header}>
            <ThemedText type="small" themeColor="textSecondary">
              Bolas is built with open-source software. These are the packages it uses and their
              licenses. Tap one to read its license.
            </ThemedText>
            <TextInput
              value={query}
              onChangeText={setQuery}
              placeholder="Search packages"
              placeholderTextColor={theme.textSecondary}
              autoCapitalize="none"
              autoCorrect={false}
              accessibilityLabel="Search packages"
              style={[styles.search, { color: theme.text, backgroundColor: theme.backgroundSelected }]}
            />
          </View>
        }
        renderItem={({ item }) => {
          const key = `${item.name}@${item.version}`;
          const isOpen = expanded === key;
          const text = item.textId === null ? null : data.texts[item.textId];
          return (
            <ThemedView type="backgroundElement" style={styles.row}>
              <Pressable
                onPress={() => setExpanded(isOpen ? null : key)}
                accessibilityRole="button"
                accessibilityState={{ expanded: isOpen }}
                accessibilityLabel={`${item.name}, version ${item.version}, ${item.license} license`}
                style={styles.rowHeader}>
                <View style={styles.rowText}>
                  <ThemedText type="smallBold">{item.name}</ThemedText>
                  <ThemedText type="small" themeColor="textSecondary">
                    {item.version} · {item.license}
                  </ThemedText>
                </View>
                <ThemedText type="default" themeColor="textSecondary">
                  {isOpen ? '–' : '+'}
                </ThemedText>
              </Pressable>
              {isOpen ? (
                <View style={styles.body}>
                  {item.repository ? (
                    <ThemedText
                      type="small"
                      themeColor="secondaryAccent"
                      style={styles.link}
                      accessibilityRole="link"
                      onPress={() =>
                        item.repository?.startsWith('http')
                          ? void openLegalUrl(item.repository)
                          : undefined
                      }>
                      {item.repository}
                    </ThemedText>
                  ) : null}
                  <ThemedText type="code" style={styles.licenseText} selectable>
                    {text ?? `Licensed under ${item.license}. This package doesn't include a license file.`}
                  </ThemedText>
                </View>
              ) : null}
            </ThemedView>
          );
        }}
        ListFooterComponent={
          <ThemedText type="small" themeColor="textSecondary" style={styles.footer}>
            {data.packages.length} packages · list generated {data.generatedAt}
          </ThemedText>
        }
      />
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  content: {
    alignSelf: 'center',
    width: '100%',
    maxWidth: MaxContentWidth,
    padding: Spacing.four,
    gap: Spacing.two,
  },
  header: {
    gap: Spacing.three,
    marginBottom: Spacing.two,
  },
  search: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
    borderRadius: Spacing.three,
    fontSize: 16,
  },
  row: {
    borderRadius: Spacing.three,
    overflow: 'hidden',
  },
  rowHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    minHeight: 48,
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
    gap: Spacing.two,
  },
  rowText: {
    flex: 1,
  },
  body: {
    paddingHorizontal: Spacing.three,
    paddingBottom: Spacing.three,
    gap: Spacing.two,
  },
  link: {
    textDecorationLine: 'underline',
  },
  licenseText: {
    fontSize: 12,
    lineHeight: 17,
  },
  footer: {
    textAlign: 'center',
    marginTop: Spacing.three,
  },
});
