import { describe, it, expect } from 'vitest';
import { TextLayer } from 'deck.gl';
import {
  capitalsLayer,
  metrosLayer,
  shouldShowMetros,
  type CapitalRow,
  type MetroRow,
} from './referenceLabelsLayer';
import capitals from '../data/capitals.json';
import metros from '../data/metros.json';

/**
 * RO-T3 tests (AC-007..011). The JSON shape/counts/bounds are pure data asserts;
 * the layer asserts mirror saturationLayer.test.ts (deck.gl TextLayer constructs
 * without a GL context, props inspectable in node).
 */

const CONUS_AKHI = { latMin: 18, latMax: 72, lngMin: -180, lngMax: -65 };

describe('capitals.json (RO-T3 / AC-007)', () => {
  it('is the 50 state capitals with {name,state,lat,lng}', () => {
    expect(capitals).toHaveLength(50);
    for (const r of capitals as CapitalRow[]) {
      expect(typeof r.name).toBe('string');
      expect(typeof r.state).toBe('string');
      expect(r.state).toMatch(/^[A-Z]{2}$/);
      expect(Number.isFinite(r.lat)).toBe(true);
      expect(Number.isFinite(r.lng)).toBe(true);
      expect(r.lat).toBeGreaterThanOrEqual(CONUS_AKHI.latMin);
      expect(r.lat).toBeLessThanOrEqual(CONUS_AKHI.latMax);
      expect(r.lng).toBeGreaterThanOrEqual(CONUS_AKHI.lngMin);
      expect(r.lng).toBeLessThanOrEqual(CONUS_AKHI.lngMax);
    }
  });

  it('has 50 unique 2-letter state codes', () => {
    const states = (capitals as CapitalRow[]).map((r) => r.state);
    expect(new Set(states).size).toBe(50);
  });
});

describe('metros.json (RO-T3 / AC-008)', () => {
  it('has [110,180] rows of {name,lat,lng,pop} with pop>=250000', () => {
    expect(metros.length).toBeGreaterThanOrEqual(110);
    expect(metros.length).toBeLessThanOrEqual(180);
    for (const r of metros as MetroRow[]) {
      expect(typeof r.name).toBe('string');
      expect(Number.isFinite(r.lat)).toBe(true);
      expect(Number.isFinite(r.lng)).toBe(true);
      expect(Number.isInteger(r.pop)).toBe(true);
      expect(r.pop).toBeGreaterThanOrEqual(250000);
    }
  });
});

describe('capitalsLayer (RO-T3 / AC-009/010)', () => {
  const row: CapitalRow = {
    name: 'Sacramento',
    state: 'CA',
    lat: 38.5767,
    lng: -121.4934,
  };
  const layer = capitalsLayer([row]);

  it('builds a TextLayer with name/position accessors', () => {
    expect(layer).toBeInstanceOf(TextLayer);
    const getText = layer.props.getText as unknown as (d: CapitalRow) => string;
    const getPosition = layer.props.getPosition as unknown as (
      d: CapitalRow,
    ) => number[];
    expect(getText(row)).toBe('Sacramento');
    expect(getPosition(row)).toEqual([-121.4934, 38.5767]);
  });

  it('carries the white sdf halo + above-anchor + pickable:false (AC-009)', () => {
    expect(layer.props.fontSettings.sdf).toBe(true);
    expect(layer.props.outlineWidth).toBeGreaterThanOrEqual(2);
    expect(layer.props.outlineColor).toEqual([255, 255, 255, 255]);
    expect(layer.props.getTextAnchor).toBe('middle');
    expect(layer.props.getAlignmentBaseline).toBe('bottom');
    expect(layer.props.pickable).toBe(false);
  });

  it('is the bold/dark/large capitals tier (AC-010)', () => {
    expect(layer.props.getSize).toBe(13);
    expect(layer.props.getColor).toEqual([40, 40, 40]);
    expect(layer.props.fontWeight).toBe(700);
    expect(layer.props.sizeUnits).toBe('pixels');
  });
});

describe('metrosLayer (RO-T3 / AC-009/010/011)', () => {
  const row: MetroRow = { name: 'Fresno', lat: 36.74, lng: -119.78, pop: 1008654 };
  const layer = metrosLayer([row]);

  it('builds a TextLayer with the metros tier values (AC-010)', () => {
    expect(layer).toBeInstanceOf(TextLayer);
    expect(layer.props.getSize).toBe(11);
    expect(layer.props.getColor).toEqual([85, 85, 85]);
    expect(layer.props.fontWeight).toBe(400);
    expect(layer.props.sizeUnits).toBe('pixels');
  });

  it('carries the halo + pickable:false (AC-009)', () => {
    expect(layer.props.fontSettings.sdf).toBe(true);
    expect(layer.props.outlineWidth).toBeGreaterThanOrEqual(2);
    expect(layer.props.pickable).toBe(false);
  });

  it('is collision-filtered with LOWER priority than capitals (AC-011)', () => {
    // The CollisionFilterExtension props ride in via spread and are not part of
    // deck.gl's static TextLayerProps type — read them through a cast.
    const metroProps = layer.props as unknown as {
      extensions: unknown[];
      getCollisionPriority: number;
      collisionGroup: string;
    };
    const capProps = capitalsLayer([]).props as unknown as {
      getCollisionPriority: number;
      collisionGroup: string;
    };
    expect(metroProps.extensions.length).toBeGreaterThanOrEqual(1);
    expect(metroProps.getCollisionPriority).toBeLessThan(
      capProps.getCollisionPriority,
    );
    expect(metroProps.collisionGroup).toBe(capProps.collisionGroup);
  });
});

describe('shouldShowMetros min-zoom gate (RO-T3 / AC-011)', () => {
  it('is false below ~zoom 5, true at/above', () => {
    expect(shouldShowMetros(4)).toBe(false);
    expect(shouldShowMetros(4.9)).toBe(false);
    expect(shouldShowMetros(5)).toBe(true);
    expect(shouldShowMetros(8)).toBe(true);
  });
});
