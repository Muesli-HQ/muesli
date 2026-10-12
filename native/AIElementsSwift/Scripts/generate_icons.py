#!/usr/bin/env python3
"""Generate SwiftUI paths from the checked-in Lucide subset (stdlib only).

SVG endpoint arcs are converted to cubic Beziers, at most 90 degrees per segment.
Fails on unsupported SVG elements/commands rather than silently dropping artwork.
"""
import math
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

def point(p):
    return f'CGPoint(x: {p[0]:.8f}, y: {p[1]:.8f})'

def arc(start, values, relative):
    rx, ry, degrees, large, sweep, x, y = values
    end = (x + start[0], y + start[1]) if relative else (x, y)
    rx, ry = abs(rx), abs(ry)
    if start == end:
        return [], end
    if rx == 0 or ry == 0:
        return [f'p.addLine(to: {point(end)})'], end
    phi = math.radians(degrees)
    c, s = math.cos(phi), math.sin(phi)
    dx, dy = (start[0]-end[0])/2, (start[1]-end[1])/2
    xp, yp = c*dx+s*dy, -s*dx+c*dy
    scale = math.sqrt(max(1, xp*xp/(rx*rx)+yp*yp/(ry*ry)))
    rx, ry = rx*scale, ry*scale
    coef = math.sqrt(max(0,(rx*rx*ry*ry-rx*rx*yp*yp-ry*ry*xp*xp)/(rx*rx*yp*yp+ry*ry*xp*xp)))
    if bool(large) == bool(sweep): coef = -coef
    cxp, cyp = coef*rx*yp/ry, -coef*ry*xp/rx
    cx = c*cxp-s*cyp+(start[0]+end[0])/2
    cy = s*cxp+c*cyp+(start[1]+end[1])/2
    a = math.atan2((yp-cyp)/ry,(xp-cxp)/rx)
    b = math.atan2((-yp-cyp)/ry,(-xp-cxp)/rx)
    delta = (b-a) % (2*math.pi)
    if not sweep: delta -= 2*math.pi
    count = max(1, math.ceil(abs(delta)/(math.pi/2)))
    step = delta/count
    def pos(t): return (cx+c*rx*math.cos(t)-s*ry*math.sin(t),cy+s*rx*math.cos(t)+c*ry*math.sin(t))
    def tangent(t): return (-c*rx*math.sin(t)-s*ry*math.cos(t),-s*rx*math.sin(t)+c*ry*math.cos(t))
    out=[]
    for i in range(count):
        t,u=a+i*step,a+(i+1)*step
        k=4/3*math.tan(step/4)
        p0,p1=pos(t),pos(u); d0,d1=tangent(t),tangent(u)
        cp1=(p0[0]+k*d0[0],p0[1]+k*d0[1]);cp2=(p1[0]-k*d1[0],p1[1]-k*d1[1])
        out.append(f'p.addCurve(to: {point(end if i==count-1 else p1)}, control1: {point(cp1)}, control2: {point(cp2)})')
    return out,end

def path(d):
    tokens=re.findall(r'[a-zA-Z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?',d)
    out=[];cursor=(0,0);origin=cursor;cmd=None;i=0
    arities={'M':2,'L':2,'H':1,'V':1,'C':6,'Q':4,'A':7}
    while i<len(tokens):
        if tokens[i].isalpha():cmd=tokens[i];i+=1
        upper=cmd.upper();relative=cmd.islower()
        if upper=='Z':out.append('p.closeSubpath()');cursor=origin;cmd=None;continue
        if upper not in arities:raise ValueError(f'Unsupported command {cmd}')
        n=arities[upper]
        if upper == 'A':
            # SVG arc flags are single characters, even in compact '0022'.
            j = i + 3
            for _ in range(2):
                token = tokens[j]
                if not token or token[0] not in '01': raise ValueError('Invalid arc flag')
                if len(token) > 1: tokens[j:j+1] = [token[0], token[1:]]
                j += 1
        v=list(map(float,tokens[i:i+n]));i+=n
        def pt(x,y):return (x+cursor[0],y+cursor[1]) if relative else (x,y)
        if upper in ('M','L'):
            end=pt(*v);out.append(f'p.{"move" if upper=="M" else "addLine"}(to: {point(end)})')
            if upper=='M':origin=end;cmd='l' if relative else 'L'
        elif upper=='H':end=(v[0]+cursor[0] if relative else v[0],cursor[1]);out.append(f'p.addLine(to: {point(end)})')
        elif upper=='V':end=(cursor[0],v[0]+cursor[1] if relative else v[0]);out.append(f'p.addLine(to: {point(end)})')
        elif upper=='C':
            end=pt(*v[4:6]);out.append(f'p.addCurve(to: {point(end)}, control1: {point(pt(*v[:2]))}, control2: {point(pt(*v[2:4]))})')
        elif upper=='Q':
            end=pt(*v[2:4]);out.append(f'p.addQuadCurve(to: {point(end)}, control: {point(pt(*v[:2]))})')
        elif upper=='A':
            lines,end=arc(cursor,v,relative);out+=lines
        cursor=end
    return out

def artwork(file):
    out=[]
    for e in ET.parse(file).getroot():
        tag=e.tag.rsplit('}',1)[-1];a=e.attrib
        if tag=='path':out+=path(a['d'])
        elif tag=='circle':
            x,y,r=map(float,(a['cx'],a['cy'],a['r']))
            out.append(f'p.addEllipse(in: CGRect(x: {x-r}, y: {y-r}, width: {2*r}, height: {2*r}))')
        elif tag=='rect':
            x,y,w,h=[float(a.get(k,0)) for k in ('x','y','width','height')];r=float(a.get('rx',0))
            out.append(f'p.addRoundedRect(in: CGRect(x: {x}, y: {y}, width: {w}, height: {h}), cornerSize: CGSize(width: {r}, height: {r}))')
        elif tag in ('line','polyline','polygon'):
            if tag=='line':pairs=[(float(a['x1']),float(a['y1'])),(float(a['x2']),float(a['y2']))]
            else:
                nums=list(map(float,re.findall(r'[-+]?[\d.]+',a['points'])));pairs=list(zip(nums[::2],nums[1::2]))
            out.append(f'p.move(to: {point(pairs[0])})')
            out += [f'p.addLine(to: {point(p)})' for p in pairs[1:]]
            if tag=='polygon':out.append('p.closeSubpath()')
        else:raise ValueError(f'Unsupported element: {tag}')
    return out

files=sorted((ROOT/'Upstream/Lucide').glob('*.svg'))
name=lambda f: f.stem.split('-')[0]+''.join(s.title() for s in f.stem.split('-')[1:])
result='''// Generated by Scripts/generate_icons.py; do not edit paths manually.
// Lucide 70562c1ee1c4fdcf736fe97bc893fb8511927934. ISC/MIT notices: Licenses/Lucide-LICENSE.
import SwiftUI

public enum AIIconName: String, CaseIterable, Sendable {
'''
result+=''.join(f'    case {name(f)}\n' for f in files)
result+='''}

/// Lucide artwork rendered directly as SwiftUI vectors. Decorative by default;
/// the enclosing control supplies its accessible label.
public struct AIIcon: View {
    public let name: AIIconName
    public let size: CGFloat
    public init(_ name: AIIconName, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }
    public var body: some View {
        LucideShape(name: name)
            .stroke(style: StrokeStyle(lineWidth: size / 12, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct LucideShape: Shape {
    let name: AIIconName
    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch name {
'''
for f in files:
    result+=f'        case .{name(f)}:\n'+''.join('            '+line+'\n' for line in artwork(f))
result+='''        }
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}
'''
(ROOT/'Sources/AIElementsSwift/AIIcon.swift').write_text(result)
print(f'Generated {len(files)} Lucide icons')
