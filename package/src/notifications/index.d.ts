// Types for react-native-impeller-platform/src/notifications.

export type PermissionStatus = 'granted' | 'denied' | 'unavailable' | 'error';
export type ShowStatus = 'shown' | 'denied' | 'unavailable' | 'error';

export interface PermissionResult {
  status: PermissionStatus;
  /** Present when status is not 'granted'. */
  reason?: string;
}

export interface ShowOptions<Data = unknown> {
  title: string;
  body?: string;
  /** Showing an id that is already on screen replaces it. Generated when omitted. */
  id?: string;
  /** Any JSON-serialisable value. It comes back unchanged in the press event. */
  data?: Data;
}

export interface ShowResult {
  status: ShowStatus;
  id: string;
  reason?: string;
}

export interface PressEvent<Data = unknown> {
  id: string;
  /** 'default': the user clicked the notification. */
  action: string;
  data: Data | null;
}

export interface Subscription {
  remove(): void;
}

export const PRESS_EVENT: 'rniNotificationPress';

export function requestPermission(): Promise<PermissionResult>;
export function show<Data = unknown>(options: ShowOptions<Data>): Promise<ShowResult>;
export function onPress<Data = unknown>(
  listener: (event: PressEvent<Data>) => void,
): Subscription;
