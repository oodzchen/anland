#!/usr/bin/env python3
"""Run the production recognizer with minimal Android stubs, no device required.

The stubs model contacts and coordinate transforms only; device/evdev delivery
and native desktop integration still require a real tablet.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'consumers/anland_v5/android_consumer/app/src/main/java/com/anland/consumer/Touchpad.java'
ACCEL = SOURCE.with_name('AndroidTouchpadAccel.java')
STUBS = {
'android/content/Context.java': 'package android.content; public class Context {}',
'android/util/Log.java': 'package android.util; public class Log { public static int d(String t,String s){return 0;} }',
'android/view/InputDevice.java': 'package android.view; public class InputDevice { public static final int SOURCE_TOUCHSCREEN=4098; }',
'android/view/ViewConfiguration.java': '''package android.view;
public class ViewConfiguration {
 public static ViewConfiguration get(android.content.Context c){return new ViewConfiguration();}
 public int getScaledTouchSlop(){return 8;}
}''',
'android/graphics/Matrix.java': '''package android.graphics;
public class Matrix {
 public float sx=1,sy=1,tx,ty;
 public void setScale(float x,float y){sx=x;sy=y;tx=ty=0;}
 public void postTranslate(float x,float y){tx+=x;ty+=y;}
}''',
'android/view/MotionEvent.java': '''package android.view;
public class MotionEvent {
 public static final int ACTION_DOWN=0,ACTION_UP=1,ACTION_MOVE=2,ACTION_CANCEL=3,
 ACTION_POINTER_DOWN=5,ACTION_POINTER_UP=6;
 private final int action,index; private final long time; private final float[] xy;
 public MotionEvent(int a,int i,long t,float... xy){action=a;index=i;time=t;this.xy=xy.clone();}
 public static MotionEvent obtain(MotionEvent e){return new MotionEvent(e.action,e.index,e.time,e.xy);}
 public int getActionMasked(){return action;} public int getActionIndex(){return index;}
 public long getEventTime(){return time;} public int getPointerCount(){return xy.length/2;}
 public int getPointerId(int i){return i;}
 public float getX(){return getX(0);} public float getY(){return getY(0);}
 public float getX(int i){return xy[i*2];} public float getY(int i){return xy[i*2+1];}
 public void setSource(int s){} public void recycle(){}
 public void transform(android.graphics.Matrix m){for(int i=0;i<xy.length;i+=2){xy[i]=xy[i]*m.sx+m.tx;xy[i+1]=xy[i+1]*m.sy+m.ty;}}
}''',
'com/anland/consumer/TouchpadTest.java': '''package com.anland.consumer;
import android.view.MotionEvent;
import static android.view.MotionEvent.*;
public class TouchpadTest implements Touchpad.Output {
 int buttons,scrolls,touches,clickpad; float moved,mx,my,scrollX,scrollY; Touchpad pad;
 TouchpadTest(boolean tap,int guard){pad=new Touchpad(new android.content.Context(),this,true);pad.setTapFilter(tap,guard,false);}
 void e(int a,int i,long t,float... xy){pad.onTouch(new MotionEvent(a,i,t,xy));}
 // A grabbed OnePlus keyboard pad: 2764x1630 units at 23 units/mm on a 3392x2400 view.
 static TouchpadTest grabbed(){TouchpadTest x=new TouchpadTest(true,0);x.pad.setInputBounds(0,0,2764,1630);
  x.pad.setOutputSize(3392,2400);x.pad.setNativeAcceleration(new AndroidTouchpadAccel(),23,23);return x;}
 // One finger travelling (dx,dy) pad units per 8 ms hardware frame for n frames.
 void slide(long t,float dx,float dy,int n){float px=1000,py=800;long ns=t*1_000_000L;
  pad.onTouch(new MotionEvent(ACTION_DOWN,0,t,px,py),ns);
  for(int i=1;i<=n;i++){px+=dx;py+=dy;ns+=8_000_000L;pad.onTouch(new MotionEvent(ACTION_MOVE,0,t+i*8,px,py),ns);}
  pad.onTouch(new MotionEvent(ACTION_UP,0,t+n*8+8,px,py),ns+8_000_000L);}
 void tap(long t){e(ACTION_DOWN,0,t,10,10);e(ACTION_UP,0,t+20,10,10);}
 void scroll(long t, boolean firstLifts){
  e(ACTION_DOWN,0,t,10,10);e(ACTION_POINTER_DOWN,1,t+10,10,10,30,10);
  e(ACTION_MOVE,0,t+20,10,30,30,30);
  e(ACTION_POINTER_UP,firstLifts?0:1,t+30,10,30,30,30);
  e(ACTION_UP,0,t+40,firstLifts?30:10,30);
 }
 // Immersive clickpad: resolve the button first, then tell the pad, as ImmersiveMode does.
 void press(long t,float... xy){clickpad=pad.clickpadButton(new MotionEvent(ACTION_MOVE,0,t,xy));pad.onPhysicalButton(true,true);}
 void release(){pad.onPhysicalButton(false,true);}
 void check(boolean ok,String name){if(!ok)throw new AssertionError(name);}
 public void onMotion(float x,float y){moved+=Math.abs(x)+Math.abs(y);mx+=x;my+=y;}
 public void onScroll(int a,float v){scrolls++;if(a==0)scrollY+=v;else scrollX+=v;}
 public void onButton(int b,boolean p){buttons++;}
 public void onTouch(int a,int i,float x,float y){touches++;} public void onTouchFrame(){}
 public float cursorX(){return 100;} public float cursorY(){return 100;}
 public static void main(String[] args){
  TouchpadTest x=new TouchpadTest(false,300);
  x.tap(1000);x.e(ACTION_DOWN,0,1100,10,10);x.e(ACTION_MOVE,0,1700,10,10);x.e(ACTION_UP,0,1720,10,10);
  x.e(ACTION_DOWN,0,2000,10,10);x.e(ACTION_POINTER_DOWN,1,2010,10,10,30,10);x.e(ACTION_POINTER_UP,1,2020,10,10,30,10);x.e(ACTION_UP,0,2030,10,10);
  x.check(x.buttons==0,"disabled: single tap, two-finger tap and long-press emit no clicks");
  x.scroll(3000,true);x.check(x.scrolls>0 && x.buttons==0,"disabled taps retain scroll");
  for(boolean first:new boolean[]{false,true}){
   x=new TouchpadTest(true,300);x.scroll(1000,first);
   x.check(x.scrolls>0 && x.buttons==0,"scroll + either lift order never clicks");
   x.tap(1100);x.check(x.buttons==0,"post-scroll recontact suppressed");
   x.tap(1500);x.check(x.buttons==2,"deliberate tap after guard works");
  }
  x=new TouchpadTest(true,0);x.scroll(1000,false);x.tap(1100);
  x.check(x.buttons==2,"zero guard allows next tap, scroll itself still never clicks");
  x=new TouchpadTest(true,300);x.e(ACTION_DOWN,0,1000,10,10);x.e(ACTION_POINTER_DOWN,1,1010,10,10,30,10);
  x.e(ACTION_MOVE,0,1020,10,30,30,30);x.e(ACTION_POINTER_UP,1,1030,10,30,30,30);
  x.e(ACTION_POINTER_DOWN,1,1040,10,30,30,30);x.e(ACTION_POINTER_UP,1,1050,10,30,30,30);x.e(ACTION_UP,0,1060,10,30);
  x.check(x.buttons==0,"finger rejoins a scroll: cannot rearm right click");
  x=new TouchpadTest(true,300);x.tap(1000);x.check(x.buttons==2,"enabled single tap works");
  x=new TouchpadTest(true,300);x.e(ACTION_DOWN,0,1000,10,10);x.e(ACTION_POINTER_DOWN,1,1010,10,10,30,10);x.e(ACTION_POINTER_UP,1,1020,10,10,30,10);x.e(ACTION_UP,0,1030,10,10);
  x.check(x.buttons==2,"enabled deliberate two-finger tap works");
  x=new TouchpadTest(true,300);x.e(ACTION_DOWN,0,1000,10,10);x.e(ACTION_MOVE,0,1600,10,10);x.pad.cancel();
  x.check(x.buttons==2,"cancel releases synthesized drag");
  // Regression: classification at a subpixel threshold used to leave right-tap armed.
  x=new TouchpadTest(true,300);x.pad.setGestureThresholds(.05f,2.35f);
  x.e(ACTION_DOWN,0,1000,10,10);x.e(ACTION_POINTER_DOWN,1,1010,10,10,30,10);x.e(ACTION_MOVE,0,1020,10,10.5f,30,10.5f);
  x.e(ACTION_POINTER_UP,1,1030,10,10.5f,30,10.5f);x.e(ACTION_UP,0,1040,10,10.5f);
  x.check(x.buttons==0,"classified subpixel scroll cannot become right click");
  // A real OnePlus trace: the leading contact moves before the other updates.
  x=new TouchpadTest(true,0);x.pad.setMultiFingerGesturesDisabled(true);
  x.e(ACTION_DOWN,0,1000,10,100);x.e(ACTION_POINTER_DOWN,1,1010,10,100,30,100);
  x.e(ACTION_MOVE,0,1050,10,100,30,70); // formerly permanently swallowed as pinch
  x.e(ACTION_MOVE,0,1060,10,65,30,60);
  x.e(ACTION_POINTER_UP,1,1070,10,65,30,60);x.e(ACTION_UP,0,1080,10,65);
  x.check(x.scrolls>0 && x.buttons==0,"lagging finger can still establish scroll");
  x=new TouchpadTest(true,0);x.pad.setMultiFingerGesturesDisabled(true);
  x.e(ACTION_DOWN,0,1000,10,100);x.e(ACTION_POINTER_DOWN,1,1010,10,100,30,100);
  x.e(ACTION_MOVE,0,1050,10,70,30,130); // actual opposite-motion pinch
  x.e(ACTION_POINTER_UP,1,1060,10,70,30,130);x.e(ACTION_UP,0,1070,10,70);
  x.check(x.scrolls==0 && x.buttons==0,"disabled pinch never falls through to right tap");
  x=new TouchpadTest(true,0);
  x.e(ACTION_DOWN,0,1000,10,10);x.e(ACTION_POINTER_DOWN,1,1010,10,10,30,10);
  x.e(ACTION_POINTER_UP,1,1400,10,10,30,10);x.e(ACTION_UP,0,1410,10,10);
  x.check(x.buttons==0,"lifting a finger must not reset the tap duration");
  x=new TouchpadTest(true,0);
  x.e(ACTION_DOWN,0,1000,10,10);x.e(ACTION_POINTER_DOWN,1,1010,10,10,30,10);
  x.e(ACTION_POINTER_UP,1,1050,10,30,30,30);x.e(ACTION_UP,0,1060,10,30);
  x.check(x.buttons==0,"movement arriving with release is not a tap");
  x=new TouchpadTest(true,0);x.scroll(1000,false);x.tap(1100);
  x.check(x.buttons==2,"default zero cooldown retains intentional post-scroll click");
  // Physical clickpad presses (immersive mode).
  x=new TouchpadTest(true,0);x.e(ACTION_DOWN,0,1000,300,300);x.press(1100,300,300);
  x.e(ACTION_MOVE,0,1120,303,302);x.e(ACTION_MOVE,0,1140,306,305);x.release();x.e(ACTION_UP,0,1200,306,305);
  x.check(x.moved==0 && x.buttons==0,"finger rolling during a click neither moves the cursor nor taps");
  x=new TouchpadTest(true,0);x.e(ACTION_DOWN,0,1000,300,300);x.press(1100,300,300);
  for(int i=1;i<=10;i++)x.e(ACTION_MOVE,0,1100+i*20,300+i*10,300);
  x.release();x.e(ACTION_UP,0,1400,400,300);
  x.check(x.moved>0 && x.buttons==0,"click-drag past the press slop moves the cursor");
  x=new TouchpadTest(true,0);x.press(1000,300,300);x.e(ACTION_DOWN,0,1000,300,300);x.release();x.e(ACTION_UP,0,1080,300,300);
  x.check(x.buttons==0,"press in the touch-down frame adds no synthetic click");
  x=new TouchpadTest(true,0);x.e(ACTION_DOWN,0,1000,300,300);x.press(1050,300,300);
  x.e(ACTION_POINTER_DOWN,1,1060,300,300,315,305);x.e(ACTION_POINTER_UP,1,1100,300,300,315,305);
  x.release();x.e(ACTION_UP,0,1150,300,300);
  x.check(x.buttons==0,"contact split while pressing is not a right tap");
  x=new TouchpadTest(true,0);x.pad.setMultiFingerGesturesDisabled(false);
  x.e(ACTION_DOWN,0,1000,300,550);x.e(ACTION_POINTER_DOWN,1,1100,300,550,400,200);x.press(1200,300,550,400,200);
  for(int i=1;i<=10;i++)x.e(ACTION_MOVE,0,1200+i*20,300,550,400+i*15,200);
  x.release();x.e(ACTION_POINTER_UP,1,1500,300,550,550,200);x.e(ACTION_UP,0,1520,300,550);
  x.check(x.moved>0 && x.touches==0 && x.scrolls==0 && x.buttons==0,"thumb holds the press, index drags the cursor");
  x=new TouchpadTest(true,0);x.e(ACTION_DOWN,0,1000,300,300);x.press(1050,300,300);x.release();
  for(int i=1;i<=5;i++)x.e(ACTION_MOVE,0,1100+i*20,300+i*10,300);
  x.e(ACTION_UP,0,1250,350,300);
  x.check(x.moved>0 && x.buttons==0,"after release the stream moves the cursor without tapping");
  x.tap(1500);x.check(x.buttons==2,"the next stream taps again");
  x=new TouchpadTest(true,0);x.pad.setOutputSize(1000,600);
  x.e(ACTION_DOWN,0,1000,700,100);x.press(1100,700,100);x.check(x.clickpad==0x110,"right half, top: left button");
  x.release();x.e(ACTION_UP,0,1200,700,100);
  x.e(ACTION_DOWN,0,2000,700,550);x.press(2100,700,550);x.check(x.clickpad==0x111,"bottom-right area: right button");
  x.release();x.e(ACTION_UP,0,2200,700,550);
  x.e(ACTION_DOWN,0,3000,300,550);x.press(3100,300,550);x.check(x.clickpad==0x110,"bottom-left: left button");
  x.release();x.e(ACTION_UP,0,3200,300,550);
  x.press(4000,700,550);x.check(x.clickpad==0x111,"no baseline: the landing contact decides");
  // Grabbed pad on Android's curve: 1 mm/frame-slow travel is 2.0416 gain at 133 DPI,
  // the same on both axes even though the pad maps onto the view anisotropically.
  x=grabbed();x.slide(1000,1,0,46);
  x.check(Math.abs(x.mx-2*2.0416f*133/25.4f)<0.05f && x.my==0,"slow pad travel matches Android's 10.7 px/mm");
  x=grabbed();x.slide(1000,0,1,46);
  x.check(Math.abs(x.my-2*2.0416f*133/25.4f)<0.05f && x.mx==0,"vertical travel matches horizontal");
  // 46 units per 8 ms is 250 mm/s: gain 9.6256 - 708.83584/250 in the top segment.
  x=grabbed();x.slide(1000,46,0,10);
  x.check(Math.abs(x.mx-20*(9.6256f-708.83584f/250)*133/25.4f)<1f,"fast travel follows the top curve segment");
  x.check(x.buttons==0,"native motion still never taps");
  // The slider scales only the native curve's output, never its input speed.
  // Cover all four curve segments, system speeds, directions and slider limits.
  for(int systemSpeed:new int[]{-7,0,7})for(float step:new float[]{1,8,16,46})
   for(float[] direction:new float[][]{{1,0},{0,-1},{0.6f,0.8f}})
    for(float multiplier:new float[]{0.5f,1,2,10}){
     TouchpadTest base=grabbed(),scaled=grabbed();
     AndroidTouchpadAccel baseCurve=new AndroidTouchpadAccel(),scaledCurve=new AndroidTouchpadAccel();
     baseCurve.setSpeedSetting(systemSpeed);scaledCurve.setSpeedSetting(systemSpeed);
     base.pad.setNativeAcceleration(baseCurve,23,23);scaled.pad.setNativeAcceleration(scaledCurve,23,23);
     scaled.pad.setAccelStrength(multiplier);
     base.slide(1000,step*direction[0],step*direction[1],8);
     scaled.slide(1000,step*direction[0],step*direction[1],8);
     x.check(base.moved>0 && Math.abs(scaled.mx-base.mx*multiplier)<0.02f
      && Math.abs(scaled.my-base.my*multiplier)<0.02f,"native slider is a fixed output multiplier in every segment");
    }
  for(float requested:new float[]{0.1f,50f}){
   TouchpadTest base=grabbed(),scaled=grabbed();scaled.pad.setAccelStrength(requested);
   base.slide(1000,23,0,8);scaled.slide(1000,23,0,8);
   float expected=requested<0.5f?0.5f:10f;
   x.check(Math.abs(scaled.mx-base.mx*expected)<0.02f,"native multiplier respects slider limits");
  }
  TouchpadTest dragBase=grabbed(),dragScaled=grabbed();dragScaled.pad.setAccelStrength(2);
  for(TouchpadTest drag:new TouchpadTest[]{dragBase,dragScaled}){
   drag.e(ACTION_DOWN,0,1000,300,550);drag.e(ACTION_POINTER_DOWN,1,1100,300,550,400,200);
   drag.press(1200,300,550,400,200);
   for(int i=1;i<=10;i++)drag.e(ACTION_MOVE,0,1200+i*8,300,550,400+i*15,200);
   drag.release();drag.e(ACTION_POINTER_UP,1,1400,300,550,550,200);drag.e(ACTION_UP,0,1420,300,550);
  }
  x.check(dragBase.mx>0 && Math.abs(dragScaled.mx-dragBase.mx*2)<0.02f,"native click-drag uses the same multiplier");
  TouchpadTest scrollBase=grabbed(),scrollScaled=grabbed();scrollScaled.pad.setAccelStrength(10);
  scrollBase.scroll(1000,false);scrollScaled.scroll(1000,false);
  x.check(scrollBase.scrolls>0 && scrollBase.scrolls==scrollScaled.scrolls
   && scrollBase.scrollX==scrollScaled.scrollX && scrollBase.scrollY==scrollScaled.scrollY,"native multiplier leaves scroll amounts unchanged");
  TouchpadTest legacyLow=grabbed(),legacyHigh=grabbed();
  legacyLow.pad.setNativeAcceleration(null,0,0);legacyHigh.pad.setNativeAcceleration(null,0,0);
  legacyLow.pad.setAccelStrength(0.5f);legacyHigh.pad.setAccelStrength(10);
  legacyLow.slide(1000,23,0,8);legacyHigh.slide(1000,23,0,8);
  x.check(legacyLow.mx>0 && legacyHigh.mx>legacyLow.mx*2,"legacy acceleration slider still works");
  System.out.println("PASS: touchpad regression scenarios including native speed multipliers, lagging contacts, pinch and clickpad presses");
 }
}'''
}
with tempfile.TemporaryDirectory(prefix='anland-touchpad-test-') as tmp:
    tmp=Path(tmp)
    for name,contents in STUBS.items():
        p=tmp/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(contents)
    subprocess.run(['javac','-d',str(tmp),str(SOURCE),str(ACCEL),*[str(tmp/p) for p in STUBS]],check=True)
    subprocess.run(['java','-cp',str(tmp),'com.anland.consumer.TouchpadTest'],check=True)
